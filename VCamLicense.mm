#import "VCamLicense.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <math.h>
#import <sys/stat.h>

static NSString * const kVCamLicenseDir = @"/var/mobile/Library/VCam";
static NSString * const kVCamDevicePath = @"/var/mobile/Library/VCam/device.id";
static NSString * const kVCamLicensePath = @"/var/mobile/Library/VCam/license.key";
static NSString * const kVCamTrialStartPath = @"/var/mobile/Library/VCam/trial.start";
static NSString * const kVCamLicenseSecret = @"QIANMIAN-VCAM-ACTIVATION-V2-2026";
static NSString * const kVCamDefaultsDeviceKey = @"com.qianmian.vcaminject.device.id";
static NSString * const kVCamDefaultsTrialStartKey = @"com.qianmian.vcaminject.trial.start";
static NSTimeInterval const kVCamTrialDuration = 2 * 60 * 60;

@interface VCamParsedLicense : NSObject
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, copy) NSString *expiry;
@property (nonatomic, copy) NSString *signature;
@end

@implementation VCamParsedLicense
@end

@implementation VCamLicense

+ (instancetype)sharedLicense {
    static VCamLicense *license;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        license = [[VCamLicense alloc] init];
    });
    return license;
}

- (NSString *)deviceCode {
    NSString *raw = [self rawDeviceCode];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < raw.length; i += 4) {
        NSUInteger len = MIN((NSUInteger)4, raw.length - i);
        [parts addObject:[raw substringWithRange:NSMakeRange(i, len)]];
    }
    return [parts componentsJoinedByString:@"-"];
}

- (NSString *)activationStatusText {
    VCamParsedLicense *license = [self parsedLicenseFromStoredCode];
    if (!license) {
        if ([self isTrialActive]) {
            return [self trialStatusText];
        }
        return @"\u8bd5\u7528\u5df2\u7ed3\u675f\uff0c\u8bf7\u6fc0\u6d3b";
    }

    if (![self isParsedLicenseValid:license allowExpired:NO]) {
        if ([self isParsedLicenseExpired:license]) {
            return @"\u6388\u6743\u5df2\u8fc7\u671f";
        }
        if ([self isTrialActive]) {
            return [self trialStatusText];
        }
        return @"\u672a\u6fc0\u6d3b";
    }

    if ([license.prefix isEqualToString:@"YP"]) {
        return @"\u6c38\u4e45\u6388\u6743";
    }

    return [NSString stringWithFormat:@"\u6388\u6743\u5230\u671f\uff1a%@", [self displayDateFromCompactDate:license.expiry]];
}

- (BOOL)isActivated {
    VCamParsedLicense *license = [self parsedLicenseFromStoredCode];
    return license && [self isParsedLicenseValid:license allowExpired:NO];
}

- (BOOL)canUseVirtualCamera {
    return [self isActivated] || [self isTrialActive];
}

- (BOOL)isTrialActive {
    if ([self isActivated]) {
        return NO;
    }

    NSTimeInterval start = [self trialStartTimeCreatingIfNeeded:YES];
    if (start <= 0) {
        return NO;
    }
    return [NSDate.date timeIntervalSince1970] - start < kVCamTrialDuration;
}

- (NSString *)trialStatusText {
    NSTimeInterval start = [self trialStartTimeCreatingIfNeeded:YES];
    NSTimeInterval remaining = kVCamTrialDuration - ([NSDate.date timeIntervalSince1970] - start);
    if (remaining <= 0) {
        return @"\u8bd5\u7528\u5df2\u7ed3\u675f\uff0c\u8bf7\u6fc0\u6d3b";
    }

    NSInteger minutes = (NSInteger)ceil(remaining / 60.0);
    NSInteger hours = minutes / 60;
    NSInteger mins = minutes % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"\u8bd5\u7528\u5269\u4f59\uff1a%ld\u5c0f\u65f6%ld\u5206\u949f", (long)hours, (long)mins];
    }
    return [NSString stringWithFormat:@"\u8bd5\u7528\u5269\u4f59\uff1a%ld\u5206\u949f", (long)MAX((NSInteger)1, mins)];
}

- (BOOL)activateWithCode:(NSString *)code {
    VCamParsedLicense *license = [self parseActivationCode:code];
    if (!license || ![self isParsedLicenseValid:license allowExpired:NO]) {
        return NO;
    }

    NSString *canonical = [self canonicalCodeForLicense:license];
    [self ensureLicenseDirectory];
    BOOL ok = [canonical writeToFile:kVCamLicensePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (ok) {
        chmod(kVCamLicensePath.UTF8String, 0666);
    }
    return ok;
}

- (void)clearActivation {
    [NSFileManager.defaultManager removeItemAtPath:kVCamLicensePath error:nil];
}

- (NSString *)rawDeviceCode {
    [self ensureLicenseDirectory];

    NSString *stored = [NSString stringWithContentsOfFile:kVCamDevicePath encoding:NSUTF8StringEncoding error:nil];
    NSString *normalized = [self normalizedAlphaNumeric:stored];
    if (normalized.length >= 16) {
        return normalized;
    }

    NSString *appStored = [self normalizedAlphaNumeric:[NSUserDefaults.standardUserDefaults stringForKey:kVCamDefaultsDeviceKey]];
    if (appStored.length >= 16) {
        [self saveDeviceCodeIfPossible:appStored];
        return appStored;
    }

    NSString *systemCode = [self stableSystemDeviceCode];
    if (systemCode.length >= 16) {
        [self saveDeviceCodeIfPossible:systemCode];
        [self saveAppDeviceCode:systemCode];
        return systemCode;
    }

    NSString *generated = [self normalizedAlphaNumeric:NSUUID.UUID.UUIDString];
    [self saveAppDeviceCode:generated];
    if ([self saveDeviceCodeIfPossible:generated]) {
        return generated;
    }

    return generated;
}

- (void)ensureLicenseDirectory {
    [NSFileManager.defaultManager createDirectoryAtPath:kVCamLicenseDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    chmod(kVCamLicenseDir.UTF8String, 0777);
}

- (BOOL)saveDeviceCodeIfPossible:(NSString *)deviceCode {
    if (deviceCode.length < 16) {
        return NO;
    }

    [self ensureLicenseDirectory];
    BOOL ok = [deviceCode writeToFile:kVCamDevicePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (!ok) {
        return NO;
    }

    chmod(kVCamDevicePath.UTF8String, 0666);
    NSString *saved = [NSString stringWithContentsOfFile:kVCamDevicePath encoding:NSUTF8StringEncoding error:nil];
    return [[self normalizedAlphaNumeric:saved] isEqualToString:deviceCode];
}

- (void)saveAppDeviceCode:(NSString *)deviceCode {
    if (deviceCode.length < 16) {
        return;
    }

    [NSUserDefaults.standardUserDefaults setObject:deviceCode forKey:kVCamDefaultsDeviceKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

- (NSTimeInterval)trialStartTimeCreatingIfNeeded:(BOOL)createIfNeeded {
    [self ensureLicenseDirectory];

    NSString *stored = [NSString stringWithContentsOfFile:kVCamTrialStartPath encoding:NSUTF8StringEncoding error:nil];
    NSTimeInterval start = stored.doubleValue;
    if (start > 0) {
        return start;
    }

    start = [NSUserDefaults.standardUserDefaults doubleForKey:kVCamDefaultsTrialStartKey];
    if (start > 0) {
        [self saveTrialStartTimeIfPossible:start];
        return start;
    }

    if (!createIfNeeded) {
        return 0;
    }

    start = [NSDate.date timeIntervalSince1970];
    [NSUserDefaults.standardUserDefaults setDouble:start forKey:kVCamDefaultsTrialStartKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    [self saveTrialStartTimeIfPossible:start];
    return start;
}

- (BOOL)saveTrialStartTimeIfPossible:(NSTimeInterval)start {
    if (start <= 0) {
        return NO;
    }

    [self ensureLicenseDirectory];
    NSString *value = [NSString stringWithFormat:@"%.0f", start];
    BOOL ok = [value writeToFile:kVCamTrialStartPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if (ok) {
        chmod(kVCamTrialStartPath.UTF8String, 0666);
    }
    return ok;
}

- (NSString *)stableSystemDeviceCode {
    typedef CFTypeRef (*MGCopyAnswerFunc)(CFStringRef);
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    MGCopyAnswerFunc copyAnswer = handle ? (MGCopyAnswerFunc)dlsym(handle, "MGCopyAnswer") : NULL;

    NSMutableString *material = [NSMutableString string];

    NSArray<NSString *> *keys = @[
        @"UniqueDeviceID",
        @"re6Zb+zwFKJNlkQTUeT+/w",
        @"SerialNumber",
        @"VasUgeSzVyHdB27g2XpN0g",
        @"UniqueChipID",
        @"aK5A62T7R++lRD3kS+oCfg"
    ];

    if (copyAnswer) {
        for (NSString *key in keys) {
            CFTypeRef answer = copyAnswer((__bridge CFStringRef)key);
            if (!answer) {
                continue;
            }
            [material appendFormat:@"%@|", (__bridge id)answer];
            CFRelease(answer);
        }
    }

    NSString *vendor = UIDevice.currentDevice.identifierForVendor.UUIDString;
    if (vendor.length > 0) {
        [material appendFormat:@"IFV:%@|", vendor];
    }

    NSString *normalized = [self normalizedAlphaNumeric:material];
    if (normalized.length < 8) {
        return nil;
    }

    NSString *hash = [self sha256HexForText:[NSString stringWithFormat:@"VCAMDEVICE|%@", normalized]];
    return [[hash substringToIndex:32] uppercaseString];
}

- (NSString *)sha256HexForText:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

- (VCamParsedLicense *)parsedLicenseFromStoredCode {
    NSString *stored = [NSString stringWithContentsOfFile:kVCamLicensePath encoding:NSUTF8StringEncoding error:nil];
    return [self parseActivationCode:stored];
}

- (VCamParsedLicense *)parseActivationCode:(NSString *)code {
    if (code.length == 0) {
        return nil;
    }

    NSString *upper = [code.uppercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    upper = [upper stringByReplacingOccurrencesOfString:@" " withString:@""];
    upper = [upper stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    upper = [upper stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    upper = [upper stringByReplacingOccurrencesOfString:@"\t" withString:@""];

    NSArray<NSString *> *parts = [upper componentsSeparatedByString:@"-"];
    NSString *prefix = nil;
    NSString *expiry = nil;
    NSMutableString *signature = [NSMutableString string];

    if (parts.count >= 3) {
        prefix = parts[0];
        expiry = [self normalizedLicenseText:parts[1]];
        for (NSUInteger i = 2; i < parts.count; i++) {
            [signature appendString:[self normalizedLicenseText:parts[i]]];
        }
    } else {
        NSString *compact = [self normalizedLicenseText:upper];
        if (compact.length >= 22 && [[compact substringToIndex:2] isEqualToString:@"YP"]) {
            prefix = @"YP";
            expiry = @"PERM";
            [signature appendString:[compact substringFromIndex:6]];
        } else if (compact.length >= 26) {
            prefix = [compact substringToIndex:2];
            expiry = [compact substringWithRange:NSMakeRange(2, 8)];
            [signature appendString:[compact substringFromIndex:10]];
        }
    }

    if (![self isSupportedPrefix:prefix] || expiry.length == 0 || signature.length < 16) {
        return nil;
    }

    VCamParsedLicense *license = [[VCamParsedLicense alloc] init];
    license.prefix = prefix;
    license.expiry = [expiry isEqualToString:@"PERM"] ? @"PERM" : [self normalizedAlphaNumeric:expiry];
    license.signature = [[signature substringToIndex:16] uppercaseString];
    return license;
}

- (BOOL)isSupportedPrefix:(NSString *)prefix {
    return [prefix isEqualToString:@"Y1"] || [prefix isEqualToString:@"YP"];
}

- (BOOL)isParsedLicenseValid:(VCamParsedLicense *)license allowExpired:(BOOL)allowExpired {
    if (!license || ![self isSupportedPrefix:license.prefix]) {
        return NO;
    }

    if (![license.prefix isEqualToString:@"YP"]) {
        if (license.expiry.length != 8 || ![license.prefix isEqualToString:@"Y1"]) {
            return NO;
        }
        if (!allowExpired && [self isParsedLicenseExpired:license]) {
            return NO;
        }
    } else if (![license.expiry isEqualToString:@"PERM"]) {
        return NO;
    }

    NSString *expected = [self expectedSignatureForPrefix:license.prefix expiry:license.expiry];
    return [license.signature isEqualToString:expected];
}

- (BOOL)isParsedLicenseExpired:(VCamParsedLicense *)license {
    if (!license || [license.prefix isEqualToString:@"YP"]) {
        return NO;
    }

    NSDate *expiryDate = [self endOfDayForCompactDate:license.expiry];
    if (!expiryDate) {
        return YES;
    }
    return [expiryDate compare:NSDate.date] == NSOrderedAscending;
}

- (NSString *)expectedSignatureForPrefix:(NSString *)prefix expiry:(NSString *)expiry {
    NSString *message = [NSString stringWithFormat:@"VCAM|v2|%@|%@|%@", [self rawDeviceCode], prefix, expiry];
    NSData *digest = [self hmacSHA256DataForMessage:message];
    return [self safeSignatureFromDigest:digest length:16];
}

- (NSData *)hmacSHA256DataForMessage:(NSString *)message {
    NSData *keyData = [kVCamLicenseSecret dataUsingEncoding:NSUTF8StringEncoding];
    NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, keyData.bytes, keyData.length, messageData.bytes, messageData.length, digest);
    return [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
}

- (NSString *)safeSignatureFromDigest:(NSData *)digest length:(NSUInteger)length {
    static const char alphabet[] = "23456789ABCDEFGH";
    const unsigned char *bytes = (const unsigned char *)digest.bytes;
    NSMutableString *out = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < digest.length && out.length < length; i++) {
        unsigned char b = bytes[i];
        [out appendFormat:@"%c", alphabet[(b >> 4) & 0x0F]];
        if (out.length >= length) {
            break;
        }
        [out appendFormat:@"%c", alphabet[b & 0x0F]];
    }
    return out;
}

- (NSString *)hmacSHA256HexForMessage:(NSString *)message {
    NSData *keyData = [kVCamLicenseSecret dataUsingEncoding:NSUTF8StringEncoding];
    NSData *messageData = [message dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, keyData.bytes, keyData.length, messageData.bytes, messageData.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

- (NSDate *)endOfDayForCompactDate:(NSString *)dateString {
    if (dateString.length != 8) {
        return nil;
    }

    NSInteger year = [[dateString substringWithRange:NSMakeRange(0, 4)] integerValue];
    NSInteger month = [[dateString substringWithRange:NSMakeRange(4, 2)] integerValue];
    NSInteger day = [[dateString substringWithRange:NSMakeRange(6, 2)] integerValue];
    if (year < 2026 || month < 1 || month > 12 || day < 1 || day > 31) {
        return nil;
    }

    NSDateComponents *components = [[NSDateComponents alloc] init];
    components.year = year;
    components.month = month;
    components.day = day;
    components.hour = 23;
    components.minute = 59;
    components.second = 59;
    return [NSCalendar.currentCalendar dateFromComponents:components];
}

- (NSString *)displayDateFromCompactDate:(NSString *)dateString {
    if (dateString.length != 8) {
        return dateString ?: @"";
    }
    return [NSString stringWithFormat:@"%@-%@-%@",
            [dateString substringWithRange:NSMakeRange(0, 4)],
            [dateString substringWithRange:NSMakeRange(4, 2)],
            [dateString substringWithRange:NSMakeRange(6, 2)]];
}

- (NSString *)canonicalCodeForLicense:(VCamParsedLicense *)license {
    NSString *sig = license.signature;
    NSMutableArray<NSString *> *sigParts = [NSMutableArray array];
    for (NSUInteger i = 0; i < sig.length; i += 4) {
        NSUInteger len = MIN((NSUInteger)4, sig.length - i);
        [sigParts addObject:[sig substringWithRange:NSMakeRange(i, len)]];
    }
    return [NSString stringWithFormat:@"%@-%@-%@", license.prefix, license.expiry, [sigParts componentsJoinedByString:@"-"]];
}

- (NSString *)normalizedAlphaNumeric:(NSString *)text {
    if (!text) {
        return @"";
    }

    NSMutableString *result = [NSMutableString string];
    NSCharacterSet *allowed = NSCharacterSet.alphanumericCharacterSet;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [result appendFormat:@"%C", c];
        }
    }
    return result.uppercaseString;
}

- (NSString *)normalizedLicenseText:(NSString *)text {
    NSMutableString *normalized = [[self normalizedAlphaNumeric:text] mutableCopy];
    [normalized replaceOccurrencesOfString:@"O"
                                withString:@"0"
                                   options:0
                                     range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"I"
                                withString:@"1"
                                   options:0
                                     range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"L"
                                withString:@"1"
                                   options:0
                                     range:NSMakeRange(0, normalized.length)];
    return normalized;
}

@end
