#import "VCamFrameProvider.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
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
@property (nonatomic, assign) NSTimeInterval activationTime;
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

    CMSampleBufferRef retimed = [self copyScaledVideoSampleBuffer:next like:sampleBuffer];
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

    CIImage *image = [CIImage imageWithCVPixelBuffer:(CVPixelBufferRef)sourceImage];
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
