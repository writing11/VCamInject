#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "VCamFrameProvider.h"
#import "VCamVideoPicker.h"

@interface VCamDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id originalDelegate;
@end

@implementation VCamDelegateProxy

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:)) {
        return YES;
    }
    return [self.originalDelegate respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    if ([self.originalDelegate respondsToSelector:aSelector]) {
        return self.originalDelegate;
    }
    return [super forwardingTargetForSelector:aSelector];
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CMSampleBufferRef virtualBuffer = [[VCamFrameProvider sharedProvider] copyVirtualSampleBufferLike:sampleBuffer];
    CMSampleBufferRef deliverBuffer = virtualBuffer ?: sampleBuffer;

    if ([self.originalDelegate respondsToSelector:_cmd]) {
        void (*msgSend)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *) =
            (void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))objc_msgSend;
        msgSend(self.originalDelegate, _cmd, output, deliverBuffer, connection);
    }

    if (virtualBuffer) {
        CFRelease(virtualBuffer);
    }
}

@end

static const void *kVCamProxyKey = &kVCamProxyKey;

static CGImageRef VCamCreateDisplayCGImageFromJPEG(NSData *jpeg) {
    if (jpeg.length == 0) {
        return nil;
    }

    UIImage *image = [UIImage imageWithData:jpeg];
    if (!image) {
        return nil;
    }

    if (image.imageOrientation == UIImageOrientationUp && image.CGImage) {
        return CGImageRetain(image.CGImage);
    }

    UIGraphicsBeginImageContextWithOptions(image.size, YES, image.scale);
    [image drawInRect:CGRectMake(0, 0, image.size.width, image.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    if (normalized.CGImage) {
        return CGImageRetain(normalized.CGImage);
    }
    return nil;
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
                          queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (!sampleBufferDelegate) {
        objc_setAssociatedObject(self, kVCamProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(nil, sampleBufferCallbackQueue);
        return;
    }

    VCamDelegateProxy *proxy = [VCamDelegateProxy new];
    proxy.originalDelegate = sampleBufferDelegate;
    objc_setAssociatedObject(self, kVCamProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig((id<AVCaptureVideoDataOutputSampleBufferDelegate>)proxy, sampleBufferCallbackQueue);
}

%end

%hook AVCapturePhoto

- (NSData *)fileDataRepresentation {
    NSData *original = %orig;
    NSData *jpeg = [[VCamFrameProvider sharedProvider] latestJPEGDataMatchingPhotoData:original];
    if (jpeg.length > 0) {
        return jpeg;
    }
    return original;
}

- (CGImageRef)CGImageRepresentation {
    NSData *jpeg = [self fileDataRepresentation];
    CGImageRef image = VCamCreateDisplayCGImageFromJPEG(jpeg);
    if (image) {
        return image;
    }
    return %orig;
}

- (CGImageRef)previewCGImageRepresentation {
    NSData *jpeg = [self fileDataRepresentation];
    CGImageRef image = VCamCreateDisplayCGImageFromJPEG(jpeg);
    if (image) {
        return image;
    }
    return %orig;
}

%end

static NSTimeInterval vcamLastTwoFingerTap = 0;

%hook UIWindow

- (void)sendEvent:(UIEvent *)event {
    %orig(event);

    if (event.type != UIEventTypeTouches) {
        return;
    }

    NSSet<UITouch *> *touches = event.allTouches;
    if (touches.count < 2) {
        return;
    }

    BOOL hasBeganTouch = NO;
    NSUInteger tapCount = 0;
    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseBegan) {
            hasBeganTouch = YES;
        }
        tapCount = MAX(tapCount, touch.tapCount);
    }

    if (!hasBeganTouch || tapCount < 1) {
        return;
    }

    NSTimeInterval now = CACurrentMediaTime();
    if (now - vcamLastTwoFingerTap <= 0.55) {
        vcamLastTwoFingerTap = 0;
        [[VCamVideoPicker sharedPicker] presentControlPanelFromWindow:self];
    } else {
        vcamLastTwoFingerTap = now;
    }
}

%end

%ctor {
    NSLog(@"[VCamInject] loaded in %@", NSBundle.mainBundle.bundleIdentifier);
}
