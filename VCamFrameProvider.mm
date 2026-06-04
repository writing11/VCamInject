#import "VCamFrameProvider.h"

#import <CoreVideo/CoreVideo.h>
#import <sys/stat.h>

static NSString * const kVCamFramePath = @"/var/mobile/Library/VCam/frame.bgra";
static NSString * const kVCamInfoPath = @"/var/mobile/Library/VCam/frame.info";

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
