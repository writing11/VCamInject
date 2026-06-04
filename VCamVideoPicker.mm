#import "VCamVideoPicker.h"

static NSString * const kVCamDir = @"/var/mobile/Library/VCam";
static NSString * const kVCamMP4Path = @"/var/mobile/Library/VCam/source.mp4";
static NSString * const kVCamMOVPath = @"/var/mobile/Library/VCam/source.mov";
static NSString * const kVCamM4VPath = @"/var/mobile/Library/VCam/source.m4v";
static NSString * const kVCamDisabledPath = @"/var/mobile/Library/VCam/disabled";

@interface VCamVideoPicker () <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, weak) UIViewController *presentingController;
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
        if (self.presenting) {
            return;
        }

        UIViewController *root = window.rootViewController ?: [self activeRootViewController];
        UIViewController *top = [self topViewControllerFrom:root];
        if (!top || top.presentedViewController) {
            return;
        }

        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
            return;
        }

        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
        picker.mediaTypes = @[@"public.movie"];
        picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
        picker.delegate = self;

        self.presenting = YES;
        self.presentingController = top;
        [top presentViewController:picker animated:YES completion:nil];
    });
}

- (void)presentControlPanelFromWindow:(UIWindow *)window {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = window.rootViewController ?: [self activeRootViewController];
        UIViewController *top = [self topViewControllerFrom:root];
        if (!top || top.presentedViewController) {
            return;
        }

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCam"
                                                                       message:@"选择虚拟相机来源"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];

        [alert addAction:[UIAlertAction actionWithTitle:@"打开相册选择视频"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [self presentFromWindow:window];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"启用视频替换"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [self enableVirtualCamera];
            [self showMessage:@"已启用视频替换" from:top];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"恢复原相机"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            [self disableVirtualCamera];
            [self showMessage:@"已恢复原相机" from:top];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        UIPopoverPresentationController *popover = alert.popoverPresentationController;
        if (popover) {
            popover.sourceView = window;
            popover.sourceRect = CGRectMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds), 1, 1);
            popover.permittedArrowDirections = 0;
        }

        [top presentViewController:alert animated:YES completion:nil];
    });
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

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
    if (mediaURL) {
        [self installVideoAtURL:mediaURL];
    }

    [picker dismissViewControllerAnimated:YES completion:^{
        self.presenting = NO;
        self.presentingController = nil;
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:^{
        self.presenting = NO;
        self.presentingController = nil;
    }];
}

- (void)installVideoAtURL:(NSURL *)url {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:kVCamDir withIntermediateDirectories:YES attributes:nil error:nil];
    [self enableVirtualCamera];

    [fm removeItemAtPath:kVCamMP4Path error:nil];
    [fm removeItemAtPath:kVCamMOVPath error:nil];
    [fm removeItemAtPath:kVCamM4VPath error:nil];

    NSString *ext = url.pathExtension.lowercaseString;
    NSString *target = kVCamMP4Path;
    if ([ext isEqualToString:@"mov"]) {
        target = kVCamMOVPath;
    } else if ([ext isEqualToString:@"m4v"]) {
        target = kVCamM4VPath;
    }

    NSError *error = nil;
    if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:target] error:&error]) {
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
        if (data) {
            [data writeToFile:target atomically:YES];
        }
    }
}

- (void)enableVirtualCamera {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:kVCamDir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:kVCamDisabledPath error:nil];
}

- (void)disableVirtualCamera {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:kVCamDir withIntermediateDirectories:YES attributes:nil error:nil];
    [@"disabled" writeToFile:kVCamDisabledPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)showMessage:(NSString *)message from:(UIViewController *)controller {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCam"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [controller presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
