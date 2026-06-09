#import "VCamVideoPicker.h"
#import "VCamFrameProvider.h"
#import "VCamLicense.h"

#import <PhotosUI/PhotosUI.h>

#define VCamText(x) @x

@interface VCamVideoPicker () <PHPickerViewControllerDelegate>
@property (nonatomic, weak) UIViewController *presentingController;
@property (nonatomic, weak) UIWindow *controlWindow;
@property (nonatomic, strong) UIButton *controlButton;
@property (nonatomic, assign) BOOL presenting;
@end

@implementation VCamVideoPicker

+ (instancetype)sharedPicker {
    static VCamVideoPicker *picker;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        picker = [[VCamVideoPicker alloc] init];
    });
    return picker;
}

- (void)presentFromWindow:(UIWindow *)window {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentPhotoPickerFromWindow:window];
    });
}

- (void)presentControlPanelFromWindow:(UIWindow *)window {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self toggleControlButtonInWindow:window];
    });
}

- (void)toggleControlButtonInWindow:(UIWindow *)window {
    if (self.controlButton.superview) {
        [self.controlButton removeFromSuperview];
        self.controlButton = nil;
        self.controlWindow = nil;
        return;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(MAX(12, window.bounds.size.width - 68), 120, 52, 52);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    button.backgroundColor = [UIColor colorWithRed:0.92 green:0.05 blue:0.05 alpha:0.9];
    button.layer.cornerRadius = 26;
    button.layer.masksToBounds = YES;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:28];
    [button setTitle:@"Y" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [button addTarget:self action:@selector(controlButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(controlButtonPanned:)];
    [button addGestureRecognizer:pan];

    [window addSubview:button];
    self.controlWindow = window;
    self.controlButton = button;
}

- (void)controlButtonTapped:(UIButton *)sender {
    [self showControlMenuFromButton:sender];
}

- (void)controlButtonPanned:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    UIView *container = view.superview;
    if (!view || !container) {
        return;
    }

    CGPoint delta = [pan translationInView:container];
    CGPoint center = CGPointMake(view.center.x + delta.x, view.center.y + delta.y);
    CGFloat halfW = CGRectGetWidth(view.bounds) / 2.0;
    CGFloat halfH = CGRectGetHeight(view.bounds) / 2.0;
    center.x = MIN(MAX(center.x, halfW + 8), CGRectGetWidth(container.bounds) - halfW - 8);
    center.y = MIN(MAX(center.y, halfH + 8), CGRectGetHeight(container.bounds) - halfH - 8);
    view.center = center;
    [pan setTranslation:CGPointZero inView:container];
}

- (void)showControlMenuFromButton:(UIButton *)button {
    UIWindow *window = self.controlWindow ?: button.window;
    UIViewController *top = [self topControllerForWindow:window];
    if (!top || top.presentedViewController) {
        return;
    }

    if (![[VCamLicense sharedLicense] canUseVirtualCamera]) {
        [self showActivationMenuFromController:top];
        return;
    }

    VCamLicense *license = [VCamLicense sharedLicense];
    NSString *status = [license activationStatusText];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCam"
                                                                   message:[NSString stringWithFormat:@"%@\n%@", VCamText("\u865a\u62df\u76f8\u673a\u63a7\u5236"), status]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u9009\u62e9\u89c6\u9891\u5e76\u66ff\u6362")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self presentPhotoPickerFromWindow:window];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u6062\u590d\u539f\u76f8\u673a")
                                             style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[VCamFrameProvider sharedProvider] disableVirtualCamera];
        [self showMessage:VCamText("\u5df2\u6062\u590d\u539f\u76f8\u673a") from:top];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u8f93\u5165\u6fc0\u6d3b\u7801")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showActivationInputFromController:top];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u9690\u85cf\u60ac\u6d6e\u6309\u94ae")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self.controlButton removeFromSuperview];
        self.controlButton = nil;
        self.controlWindow = nil;
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u53d6\u6d88")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = button;
        popover.sourceRect = button.bounds;
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }

    [top presentViewController:alert animated:YES completion:nil];
}

- (void)presentPhotoPickerFromWindow:(UIWindow *)window {
    if (self.presenting) {
        return;
    }

    UIViewController *top = [self topControllerForWindow:window];
    if (!top || top.presentedViewController) {
        return;
    }

    if (![[VCamLicense sharedLicense] canUseVirtualCamera]) {
        [self showActivationMenuFromController:top];
        return;
    }

    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.selectionLimit = 1;
        config.filter = [PHPickerFilter videosFilter];

        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;

        self.presenting = YES;
        self.presentingController = top;
        [top presentViewController:picker animated:YES completion:nil];
    } else {
        [self showMessage:VCamText("\u9700\u8981 iOS 14 \u6216\u66f4\u65b0\u7248\u672c") from:top];
    }
}

- (void)showActivationMenuFromController:(UIViewController *)controller {
    VCamLicense *license = [VCamLicense sharedLicense];
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n%@",
                         VCamText("\u8bd5\u7528\u5df2\u7ed3\u675f\uff0c\u8bf7\u6fc0\u6d3b\u540e\u7ee7\u7eed\u4f7f\u7528"),
                         VCamText("\u8bbe\u5907\u7801\uff1a"),
                         [license deviceCode]];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCam"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u8f93\u5165\u6fc0\u6d3b\u7801")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showActivationInputFromController:controller];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u590d\u5236\u8bbe\u5907\u7801")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = [license deviceCode];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showMessage:VCamText("\u8bbe\u5907\u7801\u5df2\u590d\u5236") from:controller];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u53d6\u6d88")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [controller presentViewController:alert animated:YES completion:nil];
}

- (void)showActivationInputFromController:(UIViewController *)controller {
    NSString *deviceCode = [[VCamLicense sharedLicense] deviceCode];
    NSString *message = [NSString stringWithFormat:@"%@\n%@",
                         VCamText("\u8bbe\u5907\u7801\uff1a"),
                         deviceCode];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:VCamText("\u8f93\u5165\u6fc0\u6d3b\u7801")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = VCamText("\u8bf7\u8f93\u5165\u6fc0\u6d3b\u7801");
        textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u6fc0\u6d3b")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *code = alert.textFields.firstObject.text ?: @"";
        BOOL ok = [[VCamLicense sharedLicense] activateWithCode:code];
        NSString *result = ok ? [NSString stringWithFormat:@"%@\n%@", VCamText("\u6fc0\u6d3b\u6210\u529f"), [[VCamLicense sharedLicense] activationStatusText]]
                              : VCamText("\u6fc0\u6d3b\u7801\u65e0\u6548\u6216\u5df2\u8fc7\u671f");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showMessage:result from:controller];
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:VCamText("\u53d6\u6d88")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [controller presentViewController:alert animated:YES completion:nil];
}

- (UIViewController *)topControllerForWindow:(UIWindow *)window {
    UIViewController *root = window.rootViewController ?: [self activeRootViewController];
    return [self topViewControllerFrom:root];
}

- (UIViewController *)topViewControllerFrom:(UIViewController *)controller {
    UIViewController *current = controller;
    while (current.presentedViewController) {
        current = current.presentedViewController;
    }

    if ([current isKindOfClass:UINavigationController.class]) {
        return [self topViewControllerFrom:((UINavigationController *)current).visibleViewController];
    }

    if ([current isKindOfClass:UITabBarController.class]) {
        return [self topViewControllerFrom:((UITabBarController *)current).selectedViewController];
    }

    return current;
}

- (UIViewController *)activeRootViewController {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }

        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }

        for (UIWindow *candidate in windowScene.windows) {
            if (candidate.rootViewController) {
                return candidate.rootViewController;
            }
        }
    }

    return nil;
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    [picker dismissViewControllerAnimated:YES completion:^{
        self.presenting = NO;
    }];

    PHPickerResult *result = results.firstObject;
    if (!result) {
        self.presentingController = nil;
        return;
    }

    NSItemProvider *provider = result.itemProvider;
    NSString *typeIdentifier = [self firstSupportedVideoTypeFromProvider:provider];
    if (!typeIdentifier) {
        [self showMessage:VCamText("\u6ca1\u6709\u9009\u62e9\u89c6\u9891") from:self.presentingController];
        self.presentingController = nil;
        return;
    }

    [provider loadFileRepresentationForTypeIdentifier:typeIdentifier completionHandler:^(NSURL *url, NSError *error) {
        if (!url || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showMessage:VCamText("\u8bfb\u53d6\u89c6\u9891\u5931\u8d25") from:self.presentingController];
                self.presentingController = nil;
            });
            return;
        }

        NSURL *stableURL = [self copyPickedVideoToStableTempURL:url preferredType:typeIdentifier];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (stableURL) {
                [[VCamFrameProvider sharedProvider] setLocalVideoURL:stableURL];
            } else {
                [self showMessage:VCamText("\u590d\u5236\u89c6\u9891\u5931\u8d25") from:self.presentingController];
            }
            self.presentingController = nil;
        });
    }];
}

- (NSString *)firstSupportedVideoTypeFromProvider:(NSItemProvider *)provider {
    NSArray<NSString *> *types = @[
        @"public.movie",
        @"com.apple.quicktime-movie",
        @"public.mpeg-4",
        @"public.avi"
    ];

    for (NSString *type in types) {
        if ([provider hasItemConformingToTypeIdentifier:type]) {
            return type;
        }
    }

    return nil;
}

- (NSURL *)copyPickedVideoToStableTempURL:(NSURL *)url preferredType:(NSString *)typeIdentifier {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *ext = url.pathExtension.length > 0 ? url.pathExtension.lowercaseString : [self extensionForType:typeIdentifier];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VCamSelected"];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    for (NSString *oldExt in @[@"mp4", @"mov", @"m4v", @"avi"]) {
        NSString *oldPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"selected.%@", oldExt]];
        [fm removeItemAtPath:oldPath error:nil];
    }

    NSString *targetPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"selected.%@", ext]];
    NSURL *targetURL = [NSURL fileURLWithPath:targetPath];
    [fm removeItemAtURL:targetURL error:nil];

    NSError *copyError = nil;
    if ([fm copyItemAtURL:url toURL:targetURL error:&copyError]) {
        return targetURL;
    }

    return nil;
}

- (NSString *)extensionForType:(NSString *)typeIdentifier {
    if ([typeIdentifier isEqualToString:@"public.mpeg-4"]) {
        return @"mp4";
    }
    if ([typeIdentifier isEqualToString:@"public.avi"]) {
        return @"avi";
    }
    return @"mov";
}

- (void)showMessage:(NSString *)message from:(UIViewController *)controller {
    if (!controller || controller.presentedViewController) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCam"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [controller presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
