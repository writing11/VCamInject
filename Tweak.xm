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
static const void *kVCamControlTapTargetKey = &kVCamControlTapTargetKey;
static const void *kVCamControlTapGestureKey = &kVCamControlTapGestureKey;

static void VCamUpdatePreviewLayer(AVCaptureVideoPreviewLayer *previewLayer);
static void VCamInstallControlGesture(UIWindow *window);

static BOOL VCamIsSafariFamilyProcess(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"";

    if ([bundleID isEqualToString:@"com.apple.mobilesafari"] ||
        [bundleID hasPrefix:@"com.apple.WebKit"]) {
        return YES;
    }

    if ([processName isEqualToString:@"MobileSafari"] ||
        [processName rangeOfString:@"WebContent" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [processName rangeOfString:@"WebKit" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }

    return NO;
}

static BOOL VCamShouldInitHooks(void) {
#ifdef VCAM_SAFARI_BUILD
    return VCamIsSafariFamilyProcess();
#else
    return !VCamIsSafariFamilyProcess();
#endif
}

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

@interface VCamControlTapTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation VCamControlTapTarget

- (void)vcamHandleTwoFingerDoubleTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized) {
        return;
    }

    UIWindow *window = (UIWindow *)gesture.view;
    if (![window isKindOfClass:UIWindow.class]) {
        return;
    }

    [[VCamVideoPicker sharedPicker] presentControlPanelFromWindow:window];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

@end

static void VCamInstallControlGesture(UIWindow *window) {
    if (!window) {
        return;
    }

    if (objc_getAssociatedObject(window, kVCamControlTapGestureKey)) {
        return;
    }

    VCamControlTapTarget *target = [VCamControlTapTarget new];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(vcamHandleTwoFingerDoubleTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = target;
    [window addGestureRecognizer:tap];

    objc_setAssociatedObject(window, kVCamControlTapTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kVCamControlTapGestureKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

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

%group VCamHooks

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

%hook UIWindow

- (void)makeKeyAndVisible {
    VCamInstallControlGesture(self);
    %orig;
}

- (void)setRootViewController:(UIViewController *)rootViewController {
    %orig(rootViewController);
    VCamInstallControlGesture(self);
}

- (void)sendEvent:(UIEvent *)event {
    VCamInstallControlGesture(self);
    %orig(event);
}

%end

%end

%ctor {
    if (!VCamShouldInitHooks()) {
        return;
    }
    %init(VCamHooks);
    NSLog(@"[VCamInject] loaded in %@ (%@)",
          NSBundle.mainBundle.bundleIdentifier,
          NSProcessInfo.processInfo.processName);
}
