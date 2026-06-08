#import "VCamLicense.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>

static NSString * const kVCamLicenseDir = @"/var/mobile/Library/VCam";
static NSString * const kVCamDevicePath = @"/var/mobile/Library/VCam/device.id";
static NSString * const kVCamLicensePath = @"/var/mobile/Library/VCam/license.key";
static NSString * const kVCamLicenseSecret = @"QIANMIAN-VCAM-ACTIVATION-V2-2026";

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
        return @"未激活";
    }

    if (![self isParsedLicenseValid:license allowExpired:NO]) {
        if ([self isParsedLicenseExpired:license]) {
            return @"授权已过期";
        }
        return @"未激活";
    }

    if ([license.prefix isEqualToString:@"YP"]) {
        return @"永久授权";
    }

    return [NSString stringWithFormat:@"授权到期：%@", [self displayDateFromCompactDate:license.expiry]];
}

- (BOOL)isActivated {
    VCamParsedLicense *license = [self parsedLicenseFromStoredCode];
    return license && [self isParsedLicenseValid:license allowExpired:NO];
}

- (BOOL)activateWithCode:(NSString *)code {
    VCamParsedLicense *license = [self parseActivationCode:code];
    if (!license || ![self isParsedLicenseValid:license allowExpired:NO]) {
        return NO;
    }

    NSString *canonical = [self canonicalCodeForLicense:license];
    [self ensureLicenseDirectory];
    return [canonical writeToFile:kVCamLicensePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
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

    NSString *generated = [self normalizedAlphaNumeric:NSUUID.UUID.UUIDString];
    [generated writeToFile:kVCamDevicePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return generated;
}

- (void)ensureLicenseDirectory {
    [NSFileManager.defaultManager createDirectoryAtPath:kVCamLicenseDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
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
        expiry = parts[1];
        for (NSUInteger i = 2; i < parts.count; i++) {
            [signature appendString:[self normalizedAlphaNumeric:parts[i]]];
        }
    } else {
        NSString *compact = [self normalizedAlphaNumeric:upper];
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
    return [prefix isEqualToString:@"Y7"] || [prefix isEqualToString:@"Y1"] || [prefix isEqualToString:@"YP"];
}

- (BOOL)isParsedLicenseValid:(VCamParsedLicense *)license allowExpired:(BOOL)allowExpired {
    if (!license || ![self isSupportedPrefix:license.prefix]) {
        return NO;
    }

    if (![license.prefix isEqualToString:@"YP"]) {
        if (license.expiry.length != 8 || (![license.prefix isEqualToString:@"Y7"] && ![license.prefix isEqualToString:@"Y1"])) {
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
    NSString *hmac = [self hmacSHA256HexForMessage:message];
    return [[hmac substringToIndex:16] uppercaseString];
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

@end
