#import "VCamFrameProvider.h"
#import "VCamLicense.h"

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
static NSString * const kVCamVideoAVIPath = @"/var/mobile/Library/VCam/source.avi";
static NSString * const kVCamDisabledPath = @"/var/mobile/Library/VCam/disabled";
static NSString * const kVCamScalePath = @"/var/mobile/Library/VCam/video.scale";
static CGFloat const kVCamDefaultVideoScale = 1.0;
static CGFloat const kVCamMinVideoScale = 0.35;
static CGFloat const kVCamMaxVideoScale = 3.0;

@interface VCamFrameProvider ()
@property (nonatomic, strong) AVAssetReader *assetReader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *videoOutput;
@property (nonatomic, copy) NSString *activeVideoPath;
@property (nonatomic) time_t activeVideoMTime;
@property (nonatomic, strong) NSURL *selectedVideoURL;
@property (nonatomic, strong) NSURL *activeVideoURL;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign) CGAffineTransform videoPreferredTransform;
@property (nonatomic, assign) BOOL sourceVideoPrefersPortrait;
@property (nonatomic, strong) NSData *lastJPEGData;
@property (nonatomic, strong) CIImage *lastPhotoImage;
@property (nonatomic, strong) CIImage *lastPreviewImage;
@property (nonatomic, assign) NSTimeInterval lastJPEGTime;
@property (nonatomic, assign) NSTimeInterval activationTime;
@property (nonatomic, assign) BOOL lastPhotoPrefersPortrait;
@property (nonatomic, assign) BOOL disabledInProcess;
@property (nonatomic, assign) BOOL loadedVideoScale;
@property (nonatomic, assign) CGFloat cachedVideoScale;
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

    return [self copyRawFrameSampleBufferLike:sampleBuffer frameData:frameData width:width height:height fps:fps];
    }
}

- (nullable CMSampleBufferRef)copyRawFrameSampleBufferLike:(CMSampleBufferRef)reference
                                                 frameData:(NSData *)frameData
                                                     width:(int)width
                                                    height:(int)height
                                                       fps:(int)fps {
    (void)fps;

    CVImageBufferRef referenceImage = CMSampleBufferGetImageBuffer(reference);
    if (!referenceImage || width <= 0 || height <= 0 || frameData.length < (NSUInteger)width * (NSUInteger)height * 4) {
        return nil;
    }

    size_t dstWidth = CVPixelBufferGetWidth(referenceImage);
    size_t dstHeight = CVPixelBufferGetHeight(referenceImage);
    if (dstWidth == 0 || dstHeight == 0) {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CIImage *displayImage = [[CIImage alloc] initWithBitmapData:frameData
                                                    bytesPerRow:(size_t)width * 4
                                                           size:CGSizeMake(width, height)
                                                         format:kCIFormatBGRA8
                                                     colorSpace:colorSpace];
    if (!displayImage) {
        if (colorSpace) {
            CGColorSpaceRelease(colorSpace);
        }
        return nil;
    }

    BOOL photoPrefersPortrait = height > width;
    CIImage *previewImage = [self image:displayImage byApplyingQuarterTurns:[self previewQuarterTurnsForImage:displayImage targetWidth:dstWidth targetHeight:dstHeight]];
    CGRect src = previewImage.extent;
    if (CGRectIsEmpty(src)) {
        if (colorSpace) {
            CGColorSpaceRelease(colorSpace);
        }
        return nil;
    }

    CIImage *scaled = [self image:previewImage scaledToOutputWidth:dstWidth height:dstHeight applyUserScale:YES];

    CVReturn lock = CVPixelBufferLockBaseAddress((CVPixelBufferRef)referenceImage, 0);
    if (lock != kCVReturnSuccess) {
        if (colorSpace) {
            CGColorSpaceRelease(colorSpace);
        }
        return nil;
    }

    CIContext *context = [self sharedCIContext];
    [context render:scaled
      toCVPixelBuffer:(CVPixelBufferRef)referenceImage
               bounds:CGRectMake(0, 0, dstWidth, dstHeight)
           colorSpace:colorSpace];
    [self updateLatestJPEGFromDisplayImage:displayImage previewImage:previewImage prefersPortrait:photoPrefersPortrait colorSpace:colorSpace];

    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)referenceImage, 0);
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }

    CFRetain(reference);
    return reference;
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
    [@"disabled" writeToFile:kVCamDisabledPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    chmod(kVCamDisabledPath.UTF8String, 0666);
    }
}

- (BOOL)isVirtualCameraEnabled {
    if (![[VCamLicense sharedLicense] canUseVirtualCamera]) {
        return NO;
    }
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

- (BOOL)hasAnyVirtualSource {
    @synchronized (self) {
        if (![self isVirtualCameraEnabled]) {
            return NO;
        }
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:kVCamFramePath] && [fm fileExistsAtPath:kVCamInfoPath]) {
            return YES;
        }
        return [self hasLocalVideo];
    }
}

- (CGFloat)videoScale {
    @synchronized (self) {
        if (!self.loadedVideoScale) {
            NSString *stored = [NSString stringWithContentsOfFile:kVCamScalePath encoding:NSUTF8StringEncoding error:nil];
            CGFloat value = stored.doubleValue;
            if (value <= 0) {
                value = kVCamDefaultVideoScale;
            }
            self.cachedVideoScale = [self clampedVideoScale:value];
            self.loadedVideoScale = YES;
        }
        return self.cachedVideoScale > 0 ? self.cachedVideoScale : kVCamDefaultVideoScale;
    }
}

- (void)setVideoScale:(CGFloat)scale {
    @synchronized (self) {
        self.cachedVideoScale = [self clampedVideoScale:scale];
        self.loadedVideoScale = YES;
        [self saveVideoScale:self.cachedVideoScale];
    }
}

- (CGFloat)clampedVideoScale:(CGFloat)scale {
    if (!isfinite(scale) || scale <= 0) {
        return kVCamDefaultVideoScale;
    }
    return MIN(MAX(scale, kVCamMinVideoScale), kVCamMaxVideoScale);
}

- (void)saveVideoScale:(CGFloat)scale {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:@"/var/mobile/Library/VCam" withIntermediateDirectories:YES attributes:nil error:nil];
    chmod("/var/mobile/Library/VCam", 0777);
    NSString *value = [NSString stringWithFormat:@"%.4f", [self clampedVideoScale:scale]];
    if (![fm fileExistsAtPath:kVCamScalePath]) {
        [fm createFileAtPath:kVCamScalePath contents:nil attributes:nil];
    }
    chmod(kVCamScalePath.UTF8String, 0666);
    if ([value writeToFile:kVCamScalePath atomically:NO encoding:NSUTF8StringEncoding error:nil]) {
        chmod(kVCamScalePath.UTF8String, 0666);
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
    NSArray<NSString *> *paths = @[kVCamVideoMP4Path, kVCamVideoMOVPath, kVCamVideoM4VPath, kVCamVideoAVIPath];
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
    self.videoPreferredTransform = CGAffineTransformIdentity;
    self.sourceVideoPrefersPortrait = NO;
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
    self.sourceVideoPrefersPortrait = [self trackPrefersPortrait:track];
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
    CIImage *scaled = [self image:image scaledToOutputWidth:dstWidth height:dstHeight applyUserScale:YES];

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
    CIImage *displayImage = [self photoImageFromSourceImage:sourceImage];
    BOOL photoPrefersPortrait = CGRectGetHeight(displayImage.extent) > CGRectGetWidth(displayImage.extent);
    CIImage *image = previewImage;
    CGRect src = image.extent;
    if (CGRectIsEmpty(src)) {
        CFRetain(reference);
        return reference;
    }

    CIImage *scaled = [self image:image scaledToOutputWidth:dstWidth height:dstHeight applyUserScale:YES];

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
    [self updateLatestJPEGFromDisplayImage:displayImage previewImage:previewImage prefersPortrait:photoPrefersPortrait colorSpace:colorSpace];
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
    return image;
}

- (CIImage *)photoImageFromSourceImage:(CVImageBufferRef)sourceImage {
    CIImage *rawImage = [CIImage imageWithCVPixelBuffer:(CVPixelBufferRef)sourceImage];
    return [self imageByApplyingVideoPreferredTransform:rawImage];
}

- (BOOL)trackPrefersPortrait:(AVAssetTrack *)track {
    CGSize natural = track.naturalSize;
    if (natural.width <= 0 || natural.height <= 0) {
        return NO;
    }

    CGAffineTransform t = track.preferredTransform;
    CGRect displayed = CGRectApplyAffineTransform(CGRectMake(0, 0, natural.width, natural.height), t);
    CGFloat displayWidth = fabs(CGRectGetWidth(displayed));
    CGFloat displayHeight = fabs(CGRectGetHeight(displayed));
    if (displayWidth > 0 && displayHeight > 0) {
        return displayHeight > displayWidth;
    }

    BOOL transformRotatesQuarterTurn = fabs(t.b) > fabs(t.a) || fabs(t.c) > fabs(t.d);
    if (transformRotatesQuarterTurn) {
        return natural.width > natural.height;
    }

    return natural.height > natural.width;
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

- (void)updateLatestJPEGFromDisplayImage:(CIImage *)displayImage previewImage:(CIImage *)previewImage prefersPortrait:(BOOL)prefersPortrait colorSpace:(CGColorSpaceRef)colorSpace {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - self.lastJPEGTime < 0.25) {
        return;
    }

    CGRect extent = displayImage.extent;
    if (CGRectIsEmpty(extent)) {
        return;
    }
    CIImage *normalized = [displayImage imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(extent), -CGRectGetMinY(extent))];
    CIImage *normalizedPreview = nil;
    CGRect previewExtent = previewImage.extent;
    if (!CGRectIsEmpty(previewExtent)) {
        normalizedPreview = [previewImage imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(previewExtent), -CGRectGetMinY(previewExtent))];
    }
    CGSize fallbackSize = [self fallbackPhotoSizeForImage:normalized prefersPortrait:prefersPortrait];

    NSData *jpeg = [self JPEGFromImage:normalized
                                 width:(size_t)fallbackSize.width
                                height:(size_t)fallbackSize.height
                           orientation:nil
                            colorSpace:colorSpace];
    if (jpeg.length > 0) {
        self.lastJPEGData = jpeg;
        self.lastPhotoImage = normalized;
        self.lastPreviewImage = normalizedPreview;
        self.lastPhotoPrefersPortrait = prefersPortrait;
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

- (nullable NSData *)previewJPEGDataForSize:(CGSize)size {
    @synchronized (self) {
        if (![self isVirtualCameraEnabled]) {
            return nil;
        }
        if (size.width < 2.0 || size.height < 2.0) {
            return nil;
        }

        size_t width = (size_t)MAX(1.0, floor(size.width));
        size_t height = (size_t)MAX(1.0, floor(size.height));
        CIImage *image = [self rawFramePreviewImageForWidth:width height:height];
        if (!image) {
            image = [self localVideoPreviewImageForWidth:width height:height];
        }
        if (!image && self.lastPreviewImage) {
            image = self.lastPreviewImage;
        }
        if (!image && self.lastPhotoImage) {
            image = self.lastPhotoImage;
        }
        if (!image) {
            return nil;
        }

        CGRect extent = image.extent;
        if (CGRectIsEmpty(extent)) {
            return nil;
        }

        CIImage *normalized = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-CGRectGetMinX(extent), -CGRectGetMinY(extent))];
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        BOOL prefersPortrait = CGRectGetHeight(normalized.extent) > CGRectGetWidth(normalized.extent);
        [self updateLatestJPEGFromDisplayImage:normalized previewImage:normalized prefersPortrait:prefersPortrait colorSpace:colorSpace];
        NSData *jpeg = [self JPEGFromImage:normalized
                                     width:width
                                    height:height
                               orientation:nil
                                colorSpace:colorSpace];
        if (colorSpace) {
            CGColorSpaceRelease(colorSpace);
        }
        return jpeg;
    }
}

- (nullable NSData *)latestJPEGDataMatchingPhotoData:(NSData *)photoData {
    @synchronized (self) {
        if (![self isVirtualCameraEnabled] || !self.lastPhotoImage) {
            return nil;
        }

        CGSize rawSize = [self pixelSizeFromImageData:photoData];
        if (rawSize.width <= 0 || rawSize.height <= 0) {
            return self.lastJPEGData;
        }

        NSNumber *orientation = [self orientationFromImageData:photoData];
        CGSize displaySize = [self displayPhotoSizeFromOriginalPhotoData:photoData fallbackImage:self.lastPhotoImage];
        BOOL targetPortrait = displaySize.height > displaySize.width;
        CIImage *displayImage = [self bestPhotoImageForTargetPortrait:targetPortrait];
        CIImage *outputImage = [self imagePreparedForRawPhotoStorageFromDisplayImage:displayImage orientation:orientation];

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        NSData *jpeg = [self JPEGFromImage:outputImage
                                     width:(size_t)rawSize.width
                                    height:(size_t)rawSize.height
                               orientation:orientation
                                colorSpace:colorSpace];
        if (colorSpace) {
            CGColorSpaceRelease(colorSpace);
        }
        return jpeg ?: self.lastJPEGData;
    }
}

- (CIImage *)bestPhotoImageForTargetPortrait:(BOOL)targetPortrait {
    CIImage *displayImage = self.lastPhotoImage;
    CIImage *previewImage = self.lastPreviewImage;
    if (!previewImage) {
        return displayImage;
    }

    BOOL displayPortrait = CGRectGetHeight(displayImage.extent) > CGRectGetWidth(displayImage.extent);
    BOOL previewPortrait = CGRectGetHeight(previewImage.extent) > CGRectGetWidth(previewImage.extent);
    if (displayPortrait == targetPortrait) {
        return displayImage;
    }
    if (previewPortrait == targetPortrait) {
        return previewImage;
    }
    return displayImage;
}

- (CIImage *)imagePreparedForRawPhotoStorageFromDisplayImage:(CIImage *)image orientation:(nullable NSNumber *)orientation {
    NSInteger orientationValue = orientation.integerValue;
    switch (orientationValue) {
        case 3:
        case 4:
            return [self image:image byApplyingQuarterTurns:2];
        case 6:
        case 7:
            return [self image:image byApplyingQuarterTurns:1];
        case 5:
        case 8:
            return [self image:image byApplyingQuarterTurns:-1];
        default:
            return [self image:image byApplyingQuarterTurns:0];
    }
}

- (CGSize)displayPhotoSizeFromOriginalPhotoData:(NSData *)photoData fallbackImage:(CIImage *)image {
    CGSize original = [self pixelSizeFromImageData:photoData];
    if (original.width <= 0 || original.height <= 0) {
        return [self fallbackPhotoSizeForImage:image prefersPortrait:self.lastPhotoPrefersPortrait];
    }

    NSNumber *orientation = [self orientationFromImageData:photoData];
    NSInteger orientationValue = orientation.integerValue;
    BOOL displaysWithSwappedDimensions = orientationValue == 5 || orientationValue == 6 || orientationValue == 7 || orientationValue == 8;
    if (displaysWithSwappedDimensions) {
        return CGSizeMake(original.height, original.width);
    }

    return original;
}

- (CGSize)fallbackPhotoSizeForImage:(CIImage *)image prefersPortrait:(BOOL)prefersPortrait {
    CGRect extent = image.extent;
    if (CGRectIsEmpty(extent)) {
        return CGSizeZero;
    }

    CGFloat width = CGRectGetWidth(extent);
    CGFloat height = CGRectGetHeight(extent);
    CGFloat shortSide = MIN(width, height);
    CGFloat longSide = MAX(width, height);
    return prefersPortrait ? CGSizeMake(shortSide, longSide) : CGSizeMake(longSide, shortSide);
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
    return props[(NSString *)kCGImagePropertyOrientation];
}

- (CIImage *)image:(CIImage *)image scaledToOutputWidth:(size_t)width height:(size_t)height applyUserScale:(BOOL)applyUserScale {
    CGRect src = image.extent;
    CGRect target = CGRectMake(0, 0, width, height);
    if (CGRectIsEmpty(src) || width == 0 || height == 0) {
        return [image imageByCroppingToRect:target];
    }

    CGFloat scale = MAX((CGFloat)width / CGRectGetWidth(src), (CGFloat)height / CGRectGetHeight(src));
    if (applyUserScale) {
        scale *= [self videoScale];
    }

    CGFloat scaledWidth = CGRectGetWidth(src) * scale;
    CGFloat scaledHeight = CGRectGetHeight(src) * scale;
    CGFloat tx = ((CGFloat)width - scaledWidth) * 0.5 - CGRectGetMinX(src) * scale;
    CGFloat ty = ((CGFloat)height - scaledHeight) * 0.5 - CGRectGetMinY(src) * scale;
    CIImage *scaled = [image imageByApplyingTransform:CGAffineTransformMake(scale, 0, 0, scale, tx, ty)];
    CIImage *cropped = [scaled imageByCroppingToRect:target];

    CIImage *background = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]] imageByCroppingToRect:target];
    return [cropped imageByCompositingOverImage:background];
}

- (nullable NSData *)JPEGFromImage:(CIImage *)image width:(size_t)width height:(size_t)height orientation:(nullable NSNumber *)orientation colorSpace:(CGColorSpaceRef)colorSpace {
    if (!image || width == 0 || height == 0) {
        return nil;
    }

    CGRect src = image.extent;
    if (CGRectIsEmpty(src)) {
        return nil;
    }

    CIImage *cropped = [self image:image scaledToOutputWidth:width height:height applyUserScale:YES];

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

- (nullable CIImage *)rawFramePreviewImageForWidth:(size_t)targetWidth height:(size_t)targetHeight {
    int width = 0;
    int height = 0;
    int fps = 0;
    [self readWidth:&width height:&height fps:&fps];
    if (width <= 0 || height <= 0) {
        return nil;
    }

    NSData *frameData = [NSData dataWithContentsOfFile:kVCamFramePath options:NSDataReadingMappedIfSafe error:nil];
    NSUInteger expected = (NSUInteger)width * (NSUInteger)height * 4;
    if (!frameData || frameData.length < expected) {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CIImage *image = [[CIImage alloc] initWithBitmapData:frameData
                                             bytesPerRow:(size_t)width * 4
                                                    size:CGSizeMake(width, height)
                                                  format:kCIFormatBGRA8
                                              colorSpace:colorSpace];
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }
    if (!image) {
        return nil;
    }

    return [self image:image byApplyingQuarterTurns:[self previewQuarterTurnsForImage:image targetWidth:targetWidth targetHeight:targetHeight]];
}

- (nullable CIImage *)localVideoPreviewImageForWidth:(size_t)targetWidth height:(size_t)targetHeight {
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

    CMSampleBufferRef sample = [self.videoOutput copyNextSampleBuffer];
    if (!sample) {
        [self configureLocalVideoReaderAtURL:url];
        sample = [self.videoOutput copyNextSampleBuffer];
    }
    if (!sample) {
        return nil;
    }

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
    CIImage *image = nil;
    if (imageBuffer) {
        image = [self previewImageFromSourceImage:imageBuffer targetWidth:targetWidth targetHeight:targetHeight];
    }
    CFRelease(sample);
    return image;
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
