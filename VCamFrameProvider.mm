#import "VCamFrameProvider.h"

#import <AVFoundation/AVFoundation.h>
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

    CMSampleBufferRef retimed = [self copySampleBuffer:next withTimingFrom:sampleBuffer];
    CFRelease(next);
    return retimed;
}

- (void)setLocalVideoURL:(NSURL *)url {
    self.selectedVideoURL = url;
    self.disabledInProcess = NO;
    [NSFileManager.defaultManager removeItemAtPath:kVCamDisabledPath error:nil];
    [self resetLocalVideoReader];
}

- (void)enableVirtualCamera {
    self.disabledInProcess = NO;
    [NSFileManager.defaultManager removeItemAtPath:kVCamDisabledPath error:nil];
}

- (void)disableVirtualCamera {
    self.disabledInProcess = YES;
    [self resetLocalVideoReader];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:@"/var/mobile/Library/VCam" withIntermediateDirectories:YES attributes:nil error:nil];
    [@"disabled" writeToFile:kVCamDisabledPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)isVirtualCameraEnabled {
    if (self.disabledInProcess) {
        return NO;
    }
    return ![NSFileManager.defaultManager fileExistsAtPath:kVCamDisabledPath];
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
