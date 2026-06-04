#import "VCamFrameProvider.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <sys/stat.h>

static NSString * const kVCamFramePath = @"/var/mobile/Library/VCam/frame.bgra";
static NSString * const kVCamInfoPath = @"/var/mobile/Library/VCam/frame.info";
static NSString * const kVCamVideoMP4Path = @"/var/mobile/Library/VCam/source.mp4";
static NSString * const kVCamVideoMOVPath = @"/var/mobile/Library/VCam/source.mov";
static NSString * const kVCamVideoM4VPath = @"/var/mobile/Library/VCam/source.m4v";
static NSString * const kVCamDisabledPath = @"/var/mobile/Library/VCam/disabled";

@interface VCamFrameProvider ()
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *videoOutput;
@property (nonatomic, copy) NSString *activeVideoPath;
@property (nonatomic) time_t activeVideoMTime;
@property (nonatomic, strong) NSURL *selectedVideoURL;
@property (nonatomic, strong) NSURL *activeVideoURL;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) CGAffineTransform videoPreferredTransform;
@property (nonatomic, strong) NSData *lastJPEGData;
@property (nonatomic, strong) CIImage *lastPhotoImage;
@property (nonatomic, assign) NSTimeInterval lastJPEGTime;
@property (nonatomic, assign) NSTimeInterval activationTime;
@property (nonatomic, assign) NSInteger autoPreviewRotationQuarterTurns;
@property (nonatomic, assign) NSInteger manualRotationQuarterTurns;
@property (nonatomic, assign) BOOL disabledInProcess;
@end

@implementation VCamFrameProvider

+ (instancetype)sharedProvider {
    static VCamFrameProvider *provider;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        provider = [[VCamFrameProvider alloc] init];
    });
    return provider;
}

- (nullable CMSampleBufferRef)copyVirtualSampleBufferLike:(CMSampleBufferRef)sampleBuffer {
    @synchronized (self) {
    if (![self isVirtualCameraEnabled]) {
        [self resetLocalVideoReader];
        return nil;
    }

    CGSize fallbackSize = [self sizeFromSampleBuffer:sampleBuffer];
    int width = (int)fallbackSize.width;
    int height = (int)fallbackSize.height;
    int fps = 30;

    [self readWidth:&width height:&height fps:&fps];
    if (width <= 0 || height <= 0) {
        return nil;
    }

    NSData *frameData = [NSData dataWithContentsOfFile:kVCamFramePath options:NSDataReadingMappedIfSafe error:nil];
    NSUInteger expected = (NSUInteger)width * (NSUInteger)height * 4;
    if (!frameData || frameData.length < expected) {
        CMSampleBufferRef videoBuffer = [self copyLocalVideoSampleBufferLike:sampleBuffer];
        if (videoBuffer) {
            return videoBuffer;
        }
        return nil;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };

    CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault,
                                      width,
                                      height,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)attrs,
                                      &pixelBuffer);
    if (rv != kCVReturnSuccess || !pixelBuffer) {
        return nil;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    const uint8_t *src = (const uint8_t *)frameData.bytes;
    size_t srcStride = (size_t)width * 4;

    for (int y = 0; y < height; y++) {
        memcpy(dst + (size_t)y * dstStride, src + (size_t)y * srcStride, srcStride);
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format);
    if (status != noErr || !format) {
        CVPixelBufferRelease(pixelBuffer);
        return nil;
    }

    CMSampleTimingInfo timing = [self timingFromSampleBuffer:sampleBuffer fps:fps];
    CMSampleBufferRef outBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                      pixelBuffer,
                                                      format,
                                                      &timing,
                                                      &outBuffer);

    CFRelease(format);
    CVPixelBufferRelease(pixelBuffer);

    if (status != noErr || !outBuffer) {
        return nil;
    }

    return outBuffer;
    }
}

- (nullable CMSampleBufferRef)copyLocalVideoSampleBufferLike:(CMSampleBufferRef)sampleBuffer {
    NSURL *url = [self currentVideoURL];
    if (!url) {
        [self resetLocalVideoReader];
        return nil;
    }

    BOOL needsReload = !self.assetReader ||
                       ![self.activeVideoURL isEqual:url] ||
                       self.assetReader.status == AVAssetReaderStatusFailed ||
                       self.assetReader.status == AVAssetReaderStatusCancelled ||
                       self.assetReader.status == AVAssetReaderStatusCompleted;

    if (needsReload) {
        [self configureLocalVideoReaderAtURL:url];
    }

    CMSampleBufferRef next = [self.videoOutput copyNextSampleBuffer];
    if (!next) {
        [self configureLocalVideoReaderAtURL:url];
        next = [self.videoOutput copyNextSampleBuffer];
    }

    if (!next) {
        return nil;
    }

    CMSampleBufferRef retimed = [self copyInPlaceVideoSampleBuffer:next like:sampleBuffer];
    CFRelease(next);
    return retimed;
}

- (void)setLocalVideoURL:(NSURL *)url {
    @synchronized (self) {
    self.selectedVideoURL = url;
    self.disabledInProcess = NO;
    self.activationTime = [NSDate timeIntervalSinceReferenceDate] + 1.2;
    [NSFileManager.defaultManager removeItemAtPath:kVCamDisabledPath error:nil];
    [self resetLocalVideoReader];
    }
}

- (void)enableVirtualCamera {
    @synchronized (self) {
    self.disabledInProcess = NO;
    self.activationTime = [NSDate timeIntervalSinceReferenceDate] + 0.4;
    [NSFileManager.defaultManager removeItemAtPath:kVCamDisabledPath error:nil];
    }
}

- (void)disableVirtualCamera {
    @synchronized (self) {
    self.disabledInProcess = YES;
    [self resetLocalVideoReader];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:@"/var/mobile/Library/VCam" withIntermediateDirectories:YES attributes:nil error:nil];
    [@"disabled" writeToFile:kVCamDisabledPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

- (BOOL)isVirtualCameraEnabled {
    if (self.disabledInProcess) {
        return NO;
    }
    if (self.activationTime > 0 && [NSDate timeIntervalSinceReferenceDate] < self.activationTime) {
        return NO;
    }
    return ![NSFileManager.defaultManager fileExistsAtPath:kVCamDisabledPath];
}

- (BOOL)hasLocalVideo {
    return self.selectedVideoURL != nil || [self firstExistingVideoPath] != nil;
}

- (void)rotateVideoClockwise {
    @synchronized (self) {
        self.manualRotationQuarterTurns = (self.manualRotationQuarterTurns + 1) % 4;
        self.lastJPEGData = nil;
        self.lastJPEGTime = 0;
    }
}

- (nullable NSURL *)currentVideoURL {
    if (self.selectedVideoURL) {
        return self.selectedVideoURL;
    }

    NSString *path = [self firstExistingVideoPath];
    if (!path) {
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}

- (nullable NSString *)firstExistingVideoPath {
    NSArray<NSString *> *paths = @[kVCamVideoMP4Path, kVCamVideoMOVPath, kVCamVideoM4VPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

- (void)resetLocalVideoReader {
    [self.assetReader cancelReading];
    self.assetReader = nil;
    self.videoOutput = nil;
    self.activeVideoPath = nil;
    self.activeVideoMTime = 0;
    self.activeVideoURL = nil;
}

- (void)configureLocalVideoReaderAtURL:(NSURL *)url {
    [self.assetReader cancelReading];
    self.assetReader = nil;
    self.videoOutput = nil;
    self.activeVideoURL = nil;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) {
        return;
    }

    NSError *error = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader || error) {
        return;
    }

    NSDictionary *settings = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;

    if (![reader canAddOutput:output]) {
        return;
    }
    [reader addOutput:output];

    if (![reader startReading]) {
        return;
    }

    self.assetReader = reader;
    self.videoOutput = output;
    self.activeVideoURL = url;
    self.activeVideoPath = url.path;
    self.activeVideoMTime = 0;
    self.videoPreferredTransform = track.preferredTransform;
    self.autoPreviewRotationQuarterTurns = [self previewRotationQuarterTurnsForTrack:track];
}

- (nullable CMSampleBufferRef)copySampleBuffer:(CMSampleBufferRef)source withTimingFrom:(CMSampleBufferRef)reference {
    CMSampleTimingInfo timing;
    OSStatus status = CMSampleBufferGetSampleTimingInfo(reference, 0, &timing);
    if (status != noErr) {
        CFRetain(source);
        return source;
    }

    CMSampleBufferRef copied = NULL;
    status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, source, 1, &timing, &copied);
    if (status == noErr && copied) {
        return copied;
    }

    CFRetain(source);
    return source;
}

- (nullable CMSampleBufferRef)copyScaledVideoSampleBuffer:(CMSampleBufferRef)source like:(CMSampleBufferRef)reference {
    CVImageBufferRef sourceImage = CMSampleBufferGetImageBuffer(source);
    CVImageBufferRef referenceImage = CMSampleBufferGetImageBuffer(reference);
    if (!sourceImage || !referenceImage) {
        return [self copySampleBuffer:source withTimingFrom:reference];
    }

    size_t dstWidth = CVPixelBufferGetWidth(referenceImage);
    size_t dstHeight = CVPixelBufferGetHeight(referenceImage);
    if (dstWidth == 0 || dstHeight == 0) {
        return [self copySampleBuffer:source withTimingFrom:reference];
    }

    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };

    CVPixelBufferRef dstBuffer = NULL;
    CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault,
                                      dstWidth,
                                      dstHeight,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)attrs,
                                      &dstBuffer);
    if (rv != kCVReturnSuccess || !dstBuffer) {
        return nil;
    }

    CIImage *image = [self previewImageFromSourceImage:sourceImage targetWidth:dstWidth targetHeight:dstHeight];
    CGRect src = image.extent;
    CGFloat scale = MAX((CGFloat)dstWidth / CGRectGetWidth(src), (CGFloat)dstHeight / CGRectGetHeight(src));
    CGFloat scaledWidth = CGRectGetWidth(src) * scale;
    CGFloat scaledHeight = CGRectGetHeight(src) * scale;
    CGFloat tx = ((CGFloat)dstWidth - scaledWidth) * 0.5 - CGRectGetMinX(src) * scale;
    CGFloat ty = ((CGFloat)dstHeight - scaledHeight) * 0.5 - CGRectGetMinY(src) * scale;
    CGAffineTransform transform = CGAffineTransformMake(scale, 0, 0, scale, tx, ty);
    CIImage *scaled = [image imageByApplyingTransform:transform];

    CIContext *context = [self sharedCIContext];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [context render:scaled
      toCVPixelBuffer:dstBuffer
               bounds:CGRectMake(0, 0, dstWidth, dstHeight)
           colorSpace:colorSpace];
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }

    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, dstBuffer, &format);
    if (status != noErr || !format) {
        CVPixelBufferRelease(dstBuffer);
        return nil;
    }

    CMSampleTimingInfo timing;
    status = CMSampleBufferGetSampleTimingInfo(reference, 0, &timing);
    if (status != noErr) {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef outBuffer = NULL;
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                      dstBuffer,
                                                      format,
                                                      &timing,
                                                      &outBuffer);

    CFRelease(format);
    CVPixelBufferRelease(dstBuffer);

    if (status != noErr || !outBuffer) {
        return nil;
    }

    return outBuffer;
}

- (nullable CMSampleBufferRef)copyInPlaceVideoSampleBuffer:(CMSampleBufferRef)source like:(CMSampleBufferRef)reference {
    CVImageBufferRef sourceImage = CMSampleBufferGetImageBuffer(source);
    CVImageBufferRef referenceImage = CMSampleBufferGetImageBuffer(reference);
    if (!sourceImage || !referenceImage) {
        CFRetain(reference);
        return reference;
    }

    size_t dstWidth = CVPixelBufferGetWidth(referenceImage);
    size_t dstHeight = CVPixelBufferGetHeight(referenceImage);
    if (dstWidth == 0 || dstHeight == 0) {
        CFRetain(reference);
        return reference;
    }

    CIImage *previewImage = [self previewImageFromSourceImage:sourceImage targetWidth:dstWidth targetHeight:dstHeight];
    CIImage *photoImage = [self photoImageFromSourceImage:sourceImage];
    CIImage *image = previewImage;
    CGRect src = image.extent;
    if (CGRectIsEmpty(src)) {
        CFRetain(reference);
        return reference;
    }

    CGFloat scale = MAX((CGFloat)dstWidth / CGRectGetWidth(src), (CGFloat)dstHeight / CGRectGetHeight(src));
    CGFloat scaledWidth = CGRectGetWidth(src) * scale;
    CGFloat scaledHeight = CGRectGetHeight(src) * scale;
    CGFloat tx = ((CGFloat)dstWidth - scaledWidth) * 0.5 - CGRectGetMinX(src) * scale;
    CGFloat ty = ((CGFloat)dstHeight - scaledHeight) * 0.5 - CGRectGetMinY(src) * scale;
    CGAffineTransform transform = CGAffineTransformMake(scale, 0, 0, scale, tx, ty);
    CIImage *scaled = [image imageByApplyingTransform:transform];

    CVReturn lock = CVPixelBufferLockBaseAddress((CVPixelBufferRef)referenceImage, 0);
    if (lock != kCVReturnSuccess) {
        CFRetain(reference);
        return reference;
    }

    CIContext *context = [self sharedCIContext];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    [context render:scaled
      toCVPixelBuffer:(CVPixelBufferRef)referenceImage
               bounds:CGRectMake(0, 0, dstWidth, dstHeight)
           colorSpace:colorSpace];
    [self updateLatestJPEGFromImage:photoImage colorSpace:colorSpace];
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }
    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)referenceImage, 0);

    CFRetain(reference);
    return reference;
}

- (CIImage *)previewImageFromSourceImage:(CVImageBufferRef)sourceImage targetWidth:(size_t)targetWidth targetHeight:(size_t)targetHeight {
    CIImage *rawImage = [CIImage imageWithCVPixelBuffer:(CVPixelBufferRef)sourceImage];
    CIImage *image = [self imageByApplyingVideoPreferredTransform:rawImage];
    image = [self image:image byApplyingQuarterTurns:[self previewQuarterTurnsForImage:image targetWidth:targetWidth targetHeight:targetHeight]];
    return [self imageByApplyingManualRotation:image];
}

- (CIImage *)photoImageFromSourceImage:(CVImageBufferRef)sourceImage {
    CIImage *image = [CIImage imageWithCVPixelBuffer:(CVPixelBufferRef)sourceImage];
    image = [self imageByApplyingVideoPreferredTransform:image];
    return [self imageByApplyingManualRotation:image];
}

- (CIImage *)imageByApplyingVideoPreferredTransform:(CIImage *)image {
    CGAffineTransform preferred = self.videoPreferredTransform;
    if (!CGAffineTransformIsIdentity(preferred)) {
        image = [image imageByApplyingTransform:preferred];
        CGRect extent = image.extent;
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(extent), -CGRectGetMinY(extent))];
    }

    return image;
}

- (CIImage *)imageByApplyingManualRotation:(CIImage *)image {
    return [self image:image byApplyingQuarterTurns:self.manualRotationQuarterTurns];
}

- (NSInteger)previewQuarterTurnsForImage:(CIImage *)image targetWidth:(size_t)targetWidth targetHeight:(size_t)targetHeight {
    BOOL targetLandscape = targetWidth > targetHeight;
    BOOL imagePortrait = CGRectGetHeight(image.extent) > CGRectGetWidth(image.extent);

    if (targetLandscape && imagePortrait) {
        return 1;
    }
    if (!targetLandscape && !imagePortrait) {
        return -1;
    }

    return 0;
}

- (CIImage *)image:(CIImage *)image byApplyingQuarterTurns:(NSInteger)quarterTurns {
    CGRect extent = image.extent;
    NSInteger turns = quarterTurns % 4;
    if (turns < 0) {
        turns += 4;
    }
    if (turns != 0) {
        image = [image imageByApplyingTransform:CGAffineTransformMakeRotation((CGFloat)turns * (CGFloat)M_PI_2)];
        extent = image.extent;
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(extent), -CGRectGetMinY(extent))];
    }
    return image;
}

- (NSInteger)previewRotationQuarterTurnsForTrack:(AVAssetTrack *)track {
    CGSize natural = track.naturalSize;
    CGAffineTransform t = track.preferredTransform;
    CGRect displayed = CGRectApplyAffineTransform(CGRectMake(0, 0, natural.width, natural.height), t);
    BOOL encodedLandscape = natural.width > natural.height;
    BOOL displayedPortrait = fabs(CGRectGetHeight(displayed)) > fabs(CGRectGetWidth(displayed));

    if (encodedLandscape && displayedPortrait) {
        return 1;
    }

    return 0;
}

- (void)updateLatestJPEGFromImage:(CIImage *)image colorSpace:(CGColorSpaceRef)colorSpace {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastJPEGTime < 0.25) {
        return;
    }

    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent)) {
        return;
    }
    CIImage *normalized = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(extent), -CGRectGetMinY(extent))];

    NSData *jpeg = [self JPEGFromImage:normalized
                                 width:(size_t)CGRectGetWidth(normalized.extent)
                                height:(size_t)CGRectGetHeight(normalized.extent)
                           orientation:nil
                            colorSpace:colorSpace];
    if (jpeg.length > 0) {
        self.lastJPEGData = jpeg;
        self.lastPhotoImage = normalized;
        self.lastJPEGTime = now;
    }
}

- (nullable NSData *)latestJPEGData {
    @synchronized (self) {
        if (![self isVirtualCameraEnabled]) {
            return nil;
        }
        return self.lastJPEGData;
    }
}

- (nullable NSData *)latestJPEGDataMatchingPhotoData:(NSData *)photoData {
    @synchronized (self) {
        if (![self isVirtualCameraEnabled] || !self.lastPhotoImage) {
            return nil;
        }

        CGSize size = [self outputPhotoSizeFromOriginalPhotoData:photoData virtualImage:self.lastPhotoImage];
        if (size.width <= 0 || size.height <= 0) {
            return self.lastJPEGData;
        }

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        NSData *jpeg = [self JPEGFromImage:self.lastPhotoImage
                                     width:(size_t)size.width
                                    height:(size_t)size.height
                               orientation:nil
                                colorSpace:colorSpace];
        if (colorSpace) {
            CGColorSpaceRelease(colorSpace);
        }
        return jpeg ?: self.lastJPEGData;
    }
}

- (CGSize)outputPhotoSizeFromOriginalPhotoData:(NSData *)photoData virtualImage:(CIImage *)image {
    CGSize original = [self pixelSizeFromImageData:photoData];
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent)) {
        return original;
    }
    if (original.width <= 0 || original.height <= 0) {
        return CGSizeMake(CGRectGetWidth(extent), CGRectGetHeight(extent));
    }

    BOOL originalLandscape = original.width > original.height;
    BOOL virtualLandscape = CGRectGetWidth(extent) > CGRectGetHeight(extent);
    if (originalLandscape != virtualLandscape) {
        return CGSizeMake(original.height, original.width);
    }

    return original;
}

- (CGSize)pixelSizeFromImageData:(NSData *)data {
    if (data.length == 0) {
        return CGSizeZero;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        return CGSizeZero;
    }

    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    NSNumber *width = props[(NSString *)kCGImagePropertyPixelWidth];
    NSNumber *height = props[(NSString *)kCGImagePropertyPixelHeight];
    return CGSizeMake(width.doubleValue, height.doubleValue);
}

- (nullable NSNumber *)orientationFromImageData:(NSData *)data {
    if (data.length == 0) {
        return nil;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) {
        return nil;
    }

    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    NSNumber *orientation = props[(NSString *)kCGImagePropertyOrientation];
    return orientation;
}

- (nullable NSData *)JPEGFromImage:(CIImage *)image width:(size_t)width height:(size_t)height orientation:(nullable NSNumber *)orientation colorSpace:(CGColorSpaceRef)colorSpace {
    if (!image || width == 0 || height == 0) {
        return nil;
    }

    CGRect src = image.extent;
    if (CGRectIsEmpty(src)) {
        return nil;
    }

    CGFloat scale = MAX((CGFloat)width / CGRectGetWidth(src), (CGFloat)height / CGRectGetHeight(src));
    CGFloat scaledWidth = CGRectGetWidth(src) * scale;
    CGFloat scaledHeight = CGRectGetHeight(src) * scale;
    CGFloat tx = ((CGFloat)width - scaledWidth) * 0.5 - CGRectGetMinX(src) * scale;
    CGFloat ty = ((CGFloat)height - scaledHeight) * 0.5 - CGRectGetMinY(src) * scale;
    CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMake(scale, 0, 0, scale, tx, ty)];
    CIImage *cropped = [scaled imageByCroppingToRect:CGRectMake(0, 0, width, height)];

    NSMutableDictionary *options = [@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.92} mutableCopy];
    if (orientation) {
        options[(NSString *)kCGImagePropertyOrientation] = orientation;
    }

    CGImageRef cgImage = [[self sharedCIContext] createCGImage:cropped
                                                      fromRect:CGRectMake(0, 0, width, height)
                                                        format:kCIFormatRGBA8
                                                    colorSpace:colorSpace];
    if (!cgImage) {
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
                                                                        CFSTR("public.jpeg"),
                                                                        1,
                                                                        NULL);
    if (!destination) {
        CGImageRelease(cgImage);
        return nil;
    }

    CGImageDestinationAddImage(destination, cgImage, (__bridge CFDictionaryRef)options);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(cgImage);

    return ok ? data : nil;
}

- (CIContext *)sharedCIContext {
    if (!self.ciContext) {
        self.ciContext = [CIContext contextWithOptions:nil];
    }
    return self.ciContext;
}

- (CGSize)sizeFromSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        return CGSizeMake(720, 1280);
    }
    return CGSizeMake(CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer));
}

- (CMSampleTimingInfo)timingFromSampleBuffer:(CMSampleBufferRef)sampleBuffer fps:(int)fps {
    CMSampleTimingInfo timing;
    OSStatus status = CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);
    if (status == noErr) {
        return timing;
    }

    int safeFPS = fps > 0 ? fps : 30;
    timing.duration = CMTimeMake(1, safeFPS);
    timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    timing.decodeTimeStamp = kCMTimeInvalid;
    return timing;
}

- (void)readWidth:(int *)width height:(int *)height fps:(int *)fps {
    NSString *info = [NSString stringWithContentsOfFile:kVCamInfoPath encoding:NSUTF8StringEncoding error:nil];
    if (info.length == 0) {
        return;
    }

    NSArray<NSString *> *parts = [info componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *part in parts) {
        if (part.length > 0) {
            [tokens addObject:part];
        }
    }

    if (tokens.count >= 2) {
        *width = tokens[0].intValue;
        *height = tokens[1].intValue;
    }
    if (tokens.count >= 3) {
        *fps = tokens[2].intValue;
    }
}

@end
