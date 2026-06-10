#import <Foundation/Foundation.h>

@interface VCamLicense : NSObject

+ (instancetype)sharedLicense;
- (NSString *)deviceCode;
- (NSString *)activationStatusText;
- (BOOL)isActivated;
- (BOOL)canUseVirtualCamera;
- (BOOL)isTrialActive;
- (BOOL)activateWithCode:(NSString *)code;
- (BOOL)activateWithCode:(NSString *)code errorMessage:(NSString **)errorMessage;
- (void)clearActivation;

@end
