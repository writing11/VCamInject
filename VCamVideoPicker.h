#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCamVideoPicker : NSObject
+ (instancetype)sharedPicker;
- (void)presentFromWindow:(UIWindow *)window;
@end

NS_ASSUME_NONNULL_END
