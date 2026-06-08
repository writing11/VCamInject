#import <Foundation/Foundation.h>

@interface VCamLicense : NSObject

+ (instancetype)sharedLicense;
- (NSString *)deviceCode;
- (NSString *)activationStatusText;
- (BOOL)isActivated;
- (BOOL)activateWithCode:(NSString *)code;
- (void)clearActivation;

@end
