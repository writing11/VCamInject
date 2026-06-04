#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamFrameProvider : NSObject
+ (instancetype)sharedProvider;
- (nullable CMSampleBufferRef)copyVirtualSampleBufferLike:(CMSampleBufferRef)sampleBuffer CF_RETURNS_RETAINED;
- (void)setLocalVideoURL:(NSURL *)url;
- (void)enableVirtualCamera;
- (void)disableVirtualCamera;
- (BOOL)isVirtualCameraEnabled;
- (BOOL)hasLocalVideo;
- (void)rotateVideoClockwise;
- (nullable NSData *)latestJPEGData;
- (nullable NSData *)latestJPEGDataMatchingPhotoData:(NSData *)photoData;
@end

NS_ASSUME_NONNULL_END
