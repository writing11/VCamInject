#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
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
static const void *kVCamPreviewOverlayKey = &kVCamPreviewOverlayKey;
static const void *kVCamPreviewTickerKey = &kVCamPreviewTickerKey;
static const void *kVCamPreviewDisplayLinkKey = &kVCamPreviewDisplayLinkKey;

static void VCamUpdatePreviewLayer(AVCaptureVideoPreviewLayer *previewLayer);

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

@interface VCamPreviewOverlayTicker : NSObject
@property (nonatomic, weak) AVCaptureVideoPreviewLayer *previewLayer;
@end

@implementation VCamPreviewOverlayTicker

- (void)tick:(CADisplayLink *)link {
    (void)link;
    VCamUpdatePreviewLayer(self.previewLayer);
}

@end

static CALayer *VCamOverlayLayerForPreview(AVCaptureVideoPreviewLayer *previewLayer, BOOL create) {
    if (!previewLayer) {
        return nil;
    }

    CALayer *overlay = objc_getAssociatedObject(previewLayer, kVCamPreviewOverlayKey);
    if (!overlay && create) {
        overlay = [CALayer layer];
        overlay.frame = previewLayer.bounds;
        overlay.masksToBounds = YES;
        overlay.hidden = YES;
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.backgroundColor = UIColor.clearColor.CGColor;
        [previewLayer addSublayer:overlay];
        objc_setAssociatedObject(previewLayer, kVCamPreviewOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return overlay;
}

static void VCamEnsurePreviewOverlay(AVCaptureVideoPreviewLayer *previewLayer) {
    if (!previewLayer) {
        return;
    }

    VCamOverlayLayerForPreview(previewLayer, YES);

    CADisplayLink *link = objc_getAssociatedObject(previewLayer, kVCamPreviewDisplayLinkKey);
    if (!link) {
        VCamPreviewOverlayTicker *ticker = [VCamPreviewOverlayTicker new];
        ticker.previewLayer = previewLayer;
        link = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(tick:)];
        if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
            link.preferredFramesPerSecond = 24;
        }
        [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        objc_setAssociatedObject(previewLayer, kVCamPreviewTickerKey, ticker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(previewLayer, kVCamPreviewDisplayLinkKey, link, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    VCamUpdatePreviewLayer(previewLayer);
}

static void VCamStopPreviewOverlay(AVCaptureVideoPreviewLayer *previewLayer) {
    if (!previewLayer) {
        return;
    }

    CADisplayLink *link = objc_getAssociatedObject(previewLayer, kVCamPreviewDisplayLinkKey);
    [link invalidate];
    objc_setAssociatedObject(previewLayer, kVCamPreviewDisplayLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(previewLayer, kVCamPreviewTickerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CALayer *overlay = objc_getAssociatedObject(previewLayer, kVCamPreviewOverlayKey);
    [overlay removeFromSuperlayer];
    objc_setAssociatedObject(previewLayer, kVCamPreviewOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void VCamUpdatePreviewLayer(AVCaptureVideoPreviewLayer *previewLayer) {
    if (!previewLayer) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VCamUpdatePreviewLayer(previewLayer);
        });
        return;
    }

    CALayer *overlay = VCamOverlayLayerForPreview(previewLayer, YES);
    overlay.frame = previewLayer.bounds;

    VCamFrameProvider *provider = [VCamFrameProvider sharedProvider];
    if (![provider hasAnyVirtualSource]) {
        overlay.hidden = YES;
        overlay.contents = nil;
        return;
    }

    CGSize size = previewLayer.bounds.size;
    NSData *jpeg = [provider previewJPEGDataForSize:size];
    if (jpeg.length == 0) {
        overlay.hidden = YES;
        overlay.contents = nil;
        return;
    }

    CGImageRef image = VCamCreateDisplayCGImageFromJPEG(jpeg);
    if (image) {
        overlay.contents = (__bridge id)image;
        overlay.hidden = NO;
        CGImageRelease(image);
    } else {
        overlay.hidden = YES;
        overlay.contents = nil;
    }
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

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    self = %orig(session);
    if (self) {
        VCamEnsurePreviewOverlay(self);
    }
    return self;
}

+ (instancetype)layerWithSession:(AVCaptureSession *)session {
    AVCaptureVideoPreviewLayer *layer = %orig(session);
    VCamEnsurePreviewOverlay(layer);
    return layer;
}

- (void)layoutSublayers {
    %orig;
    VCamEnsurePreviewOverlay(self);
}

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    VCamEnsurePreviewOverlay(self);
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    VCamEnsurePreviewOverlay(self);
}

- (void)removeFromSuperlayer {
    VCamStopPreviewOverlay(self);
    %orig;
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
    if (touches.count != 2) {
        return;
    }

    NSUInteger beganCount = 0;
    NSUInteger tapCount = 0;
    for (UITouch *touch in touches) {
        if (touch.phase == UITouchPhaseBegan) {
            beganCount++;
        }
        tapCount = MAX(tapCount, touch.tapCount);
    }

    if (beganCount != 2 || tapCount < 1) {
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
