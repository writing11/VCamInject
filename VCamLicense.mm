#import "VCamLicense.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <arpa/inet.h>
#import <errno.h>
#import <math.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <string.h>
#import <unistd.h>

static NSString * const kVCamLicenseDir = @"/var/mobile/Library/VCam";
static NSString * const kVCamDevicePath = @"/var/mobile/Library/VCam/device.id";
static NSString * const kVCamLicensePath = @"/var/mobile/Library/VCam/license.key";
static NSString * const kVCamTrialStartPath = @"/var/mobile/Library/VCam/trial.start";
static NSString * const kVCamDefaultsDeviceKey = @"device.id";
static NSString * const kVCamDefaultsLicenseKey = @"license.key";
static NSString * const kVCamDefaultsTrialStartKey = @"trial.start";
static NSString * const kVCamLicenseSecret = @"QIANMIAN-VCAM-ACTIVATION-V2-2026";
static NSTimeInterval const kVCamTrialDuration = 2 * 60 * 60;
static const int kVCamDaemonPort = 9999;
static NSString *gVCamCachedDeviceCode = nil;
static NSString *gVCamCachedLicenseCode = nil;
static NSTimeInterval gVCamCachedTrialStart = 0;

static BOOL VCamSocketSendAll(int fd, const void *bytes, size_t length) {
    const uint8_t *p = (const uint8_t *)bytes;
    size_t sent = 0;
    while (sent < length) {
        ssize_t n = send(fd, p + sent, length - sent, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return NO;
        }
        if (n == 0) {
            return NO;
        }
        sent += (size_t)n;
    }
    return YES;
}

static NSString *VCamSocketReadLine(int fd) {
    char buf[256];
    size_t len = 0;
    while (len + 1 < sizeof(buf)) {
        char c = 0;
        ssize_t n = recv(fd, &c, 1, 0);
        if (n == 0) {
            break;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return nil;
        }
        if (c == '\n') {
            break;
        }
        buf[len++] = c;
    }
    buf[len] = '\0';
    return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
}

static NSData *VCamSocketReadExactData(int fd, NSUInteger length) {
    if (length == 0) {
        return [NSData data];
    }

    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *p = (uint8_t *)data.mutableBytes;
    NSUInteger got = 0;
    while (got < length) {
        ssize_t n = recv(fd, p + got, length - got, 0);
        if (n == 0) {
            return nil;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return nil;
        }
        got += (NSUInteger)n;
    }
    return data;
}

static int VCamOpenControlSocket(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 250000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kVCamDaemonPort);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    uint8_t handshake[44] = {0};
    memcpy(handshake, "VCAMCTL1", 8);
    if (!VCamSocketSendAll(fd, handshake, sizeof(handshake))) {
        close(fd);
        return -1;
    }

    uint8_t ack = 0;
    ssize_t n = recv(fd, &ack, 1, 0);
    if (n != 1 || ack != 0x01) {
        close(fd);
        return -1;
    }

    return fd;
}

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
    if ([self normalizedAlphaNumeric:raw].length < 16) {
        return raw.length > 0 ? raw : @"\u5168\u5c40\u670d\u52a1\u672a\u542f\u52a8";
    }

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

    NSInteger totalSeconds = MAX((NSInteger)1, (NSInteger)floor(remaining));
    NSInteger hours = totalSeconds / 3600;
    NSInteger mins = (totalSeconds % 3600) / 60;
    NSInteger secs = totalSeconds % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"\u8bd5\u7528\u5269\u4f59\uff1a%ld\u5c0f\u65f6%ld\u5206%ld\u79d2", (long)hours, (long)mins, (long)secs];
    }
    if (mins > 0) {
        return [NSString stringWithFormat:@"\u8bd5\u7528\u5269\u4f59\uff1a%ld\u5206%ld\u79d2", (long)mins, (long)secs];
    }
    return [NSString stringWithFormat:@"\u8bd5\u7528\u5269\u4f59\uff1a%ld\u79d2", (long)secs];
}

- (BOOL)activateWithCode:(NSString *)code {
    VCamParsedLicense *license = [self parseActivationCode:code];
    if (!license || ![self isParsedLicenseValid:license allowExpired:NO]) {
        return NO;
    }

    NSString *canonical = [self canonicalCodeForLicense:license];
    BOOL saved = [self writePersistentString:canonical filePath:kVCamLicensePath defaultsKey:kVCamDefaultsLicenseKey];
    if (!saved) {
        return NO;
    }

    @synchronized (VCamLicense.class) {
        gVCamCachedLicenseCode = [canonical copy];
    }
    VCamParsedLicense *savedLicense = [self parsedLicenseFromStoredCode];
    return savedLicense &&
           [self isParsedLicenseValid:savedLicense allowExpired:NO] &&
           [[self canonicalCodeForLicense:savedLicense] isEqualToString:canonical];
}

- (void)clearActivation {
    [NSFileManager.defaultManager removeItemAtPath:kVCamLicensePath error:nil];
    [self removePersistentDefaultsValueForKey:kVCamDefaultsLicenseKey];
    @synchronized (VCamLicense.class) {
        gVCamCachedLicenseCode = nil;
    }
}

- (NSString *)rawDeviceCode {
    [self ensureLicenseDirectory];

    NSString *cached = [self normalizedAlphaNumeric:gVCamCachedDeviceCode];
    if (cached.length >= 16) {
        return cached;
    }

    NSString *global = [self persistentDefaultsStringForKey:kVCamDefaultsDeviceKey];
    NSString *normalized = [self normalizedAlphaNumeric:global];
    if (normalized.length >= 16) {
        [self saveDeviceCodeIfPossible:normalized];
        return [self cacheAndReturnDeviceCode:normalized];
    }

    NSString *stored = [NSString stringWithContentsOfFile:kVCamDevicePath encoding:NSUTF8StringEncoding error:nil];
    normalized = [self normalizedAlphaNumeric:stored];
    if (normalized.length >= 16) {
        [self saveDeviceCodeIfPossible:normalized];
        return [self cacheAndReturnDeviceCode:normalized];
    }

    return @"\u5168\u5c40\u670d\u52a1\u672a\u542f\u52a8";
}

- (NSString *)cacheAndReturnDeviceCode:(NSString *)deviceCode {
    NSString *normalized = [self normalizedAlphaNumeric:deviceCode];
    if (normalized.length >= 16) {
        @synchronized (VCamLicense.class) {
            gVCamCachedDeviceCode = [normalized copy];
        }
    }
    return normalized;
}

- (void)ensureLicenseDirectory {
    [NSFileManager.defaultManager createDirectoryAtPath:kVCamLicenseDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    chmod(kVCamLicenseDir.UTF8String, 0777);
}

- (NSString *)filePathForPersistentKey:(NSString *)key {
    if ([key isEqualToString:kVCamDefaultsDeviceKey]) {
        return kVCamDevicePath;
    }
    if ([key isEqualToString:kVCamDefaultsLicenseKey]) {
        return kVCamLicensePath;
    }
    if ([key isEqualToString:kVCamDefaultsTrialStartKey]) {
        return kVCamTrialStartPath;
    }
    return nil;
}

- (BOOL)writePersistentString:(NSString *)value filePath:(NSString *)filePath defaultsKey:(NSString *)key {
    if (value.length == 0 || key.length == 0) {
        return NO;
    }

    BOOL wroteDaemon = [self writeDaemonString:value forKey:key];
    BOOL wroteFile = NO;
    if (filePath.length > 0) {
        [self ensureLicenseDirectory];
        if (![NSFileManager.defaultManager fileExistsAtPath:filePath]) {
            [NSFileManager.defaultManager createFileAtPath:filePath contents:nil attributes:nil];
        }
        chmod(filePath.UTF8String, 0666);
        wroteFile = [value writeToFile:filePath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        if (wroteFile) {
            chmod(filePath.UTF8String, 0666);
        }
    }

    return wroteDaemon || wroteFile;
}

- (NSString *)persistentDefaultsStringForKey:(NSString *)key {
    NSString *value = [self daemonStringForKey:key];
    if (value.length > 0) {
        return value;
    }

    NSString *filePath = [self filePathForPersistentKey:key];
    value = filePath.length > 0 ? [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil] : nil;
    return value.length > 0 ? value : nil;
}

- (void)removePersistentDefaultsValueForKey:(NSString *)key {
    [self removeDaemonStringForKey:key];
    NSString *filePath = [self filePathForPersistentKey:key];
    if (filePath.length > 0) {
        [NSFileManager.defaultManager removeItemAtPath:filePath error:nil];
    }
}

- (NSString *)daemonStringForKey:(NSString *)key {
    if (key.length == 0) {
        return nil;
    }

    int fd = VCamOpenControlSocket();
    if (fd < 0) {
        return nil;
    }

    NSString *command = [NSString stringWithFormat:@"GET %@\n", key];
    NSData *commandData = [command dataUsingEncoding:NSUTF8StringEncoding];
    NSString *result = nil;
    if (VCamSocketSendAll(fd, commandData.bytes, commandData.length)) {
        NSString *header = VCamSocketReadLine(fd);
        NSArray<NSString *> *parts = [header componentsSeparatedByString:@" "];
        if (parts.count >= 2 && [parts[0] isEqualToString:@"OK"]) {
            NSUInteger length = (NSUInteger)MAX((NSInteger)0, parts[1].integerValue);
            NSData *payload = VCamSocketReadExactData(fd, length);
            if (payload) {
                result = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
            }
        }
    }
    close(fd);
    return result.length > 0 ? result : nil;
}

- (BOOL)writeDaemonString:(NSString *)value forKey:(NSString *)key {
    if (value.length == 0 || key.length == 0) {
        return NO;
    }

    NSData *payload = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (payload.length == 0 || payload.length > 4096) {
        return NO;
    }

    int fd = VCamOpenControlSocket();
    if (fd < 0) {
        return NO;
    }

    NSString *command = [NSString stringWithFormat:@"SET %@ %lu\n", key, (unsigned long)payload.length];
    NSData *commandData = [command dataUsingEncoding:NSUTF8StringEncoding];
    BOOL ok = VCamSocketSendAll(fd, commandData.bytes, commandData.length) &&
              VCamSocketSendAll(fd, payload.bytes, payload.length);
    if (ok) {
        NSString *header = VCamSocketReadLine(fd);
        ok = [header hasPrefix:@"OK "];
    }
    close(fd);
    return ok;
}

- (void)removeDaemonStringForKey:(NSString *)key {
    if (key.length == 0) {
        return;
    }

    int fd = VCamOpenControlSocket();
    if (fd < 0) {
        return;
    }

    NSString *command = [NSString stringWithFormat:@"DEL %@\n", key];
    NSData *commandData = [command dataUsingEncoding:NSUTF8StringEncoding];
    if (VCamSocketSendAll(fd, commandData.bytes, commandData.length)) {
        (void)VCamSocketReadLine(fd);
    }
    close(fd);
}

- (BOOL)saveDeviceCodeIfPossible:(NSString *)deviceCode {
    if (deviceCode.length < 16) {
        return NO;
    }

    [self ensureLicenseDirectory];
    BOOL ok = [self writePersistentString:deviceCode filePath:kVCamDevicePath defaultsKey:kVCamDefaultsDeviceKey];
    NSString *saved = [NSString stringWithContentsOfFile:kVCamDevicePath encoding:NSUTF8StringEncoding error:nil];
    NSString *fallback = [self persistentDefaultsStringForKey:kVCamDefaultsDeviceKey];
    return ok ||
           [[self normalizedAlphaNumeric:saved] isEqualToString:deviceCode] ||
           [[self normalizedAlphaNumeric:fallback] isEqualToString:deviceCode];
}

- (NSTimeInterval)trialStartTimeCreatingIfNeeded:(BOOL)createIfNeeded {
    @synchronized (VCamLicense.class) {
        if (gVCamCachedTrialStart > 0) {
            return gVCamCachedTrialStart;
        }
    }

    [self ensureLicenseDirectory];

    NSTimeInterval fileStart = [NSString stringWithContentsOfFile:kVCamTrialStartPath encoding:NSUTF8StringEncoding error:nil].doubleValue;
    NSTimeInterval fallbackStart = [self persistentDefaultsStringForKey:kVCamDefaultsTrialStartKey].doubleValue;
    NSTimeInterval start = 0;
    if (fileStart > 0 && fallbackStart > 0) {
        start = MIN(fileStart, fallbackStart);
    } else {
        start = MAX(fileStart, fallbackStart);
    }

    if (start > 0) {
        @synchronized (VCamLicense.class) {
            gVCamCachedTrialStart = start;
        }
        [self saveTrialStartTimeIfPossible:start];
        return start;
    }

    if (!createIfNeeded) {
        return 0;
    }

    start = [NSDate.date timeIntervalSince1970];
    if (![self saveTrialStartTimeIfPossible:start]) {
        return 0;
    }

    @synchronized (VCamLicense.class) {
        gVCamCachedTrialStart = start;
    }
    return start;
}

- (BOOL)saveTrialStartTimeIfPossible:(NSTimeInterval)start {
    if (start <= 0) {
        return NO;
    }

    NSString *value = [NSString stringWithFormat:@"%.0f", start];
    return [self writePersistentString:value filePath:kVCamTrialStartPath defaultsKey:kVCamDefaultsTrialStartKey];
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
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    @synchronized (VCamLicense.class) {
        if (gVCamCachedLicenseCode.length > 0) {
            [codes addObject:gVCamCachedLicenseCode];
        }
    }

    NSString *stored = [NSString stringWithContentsOfFile:kVCamLicensePath encoding:NSUTF8StringEncoding error:nil];
    if (stored.length > 0) {
        [codes addObject:stored];
    }

    NSString *fallback = [self persistentDefaultsStringForKey:kVCamDefaultsLicenseKey];
    if (fallback.length > 0) {
        [codes addObject:fallback];
    }

    VCamParsedLicense *firstParsed = nil;
    for (NSString *code in codes) {
        VCamParsedLicense *license = [self parseActivationCode:code];
        if (!license) {
            continue;
        }
        if (!firstParsed) {
            firstParsed = license;
        }
        if ([self isParsedLicenseValid:license allowExpired:NO]) {
            return license;
        }
    }
    return firstParsed;
}

- (VCamParsedLicense *)parseActivationCode:(NSString *)code {
    if (code.length == 0) {
        return nil;
    }

    NSString *upper = [code.uppercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *dash in @[@"\u2010", @"\u2011", @"\u2012", @"\u2013", @"\u2014", @"\u2212", @"\uFF0D"]) {
        upper = [upper stringByReplacingOccurrencesOfString:dash withString:@"-"];
    }
    upper = [[upper componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];

    NSArray<NSString *> *parts = [upper componentsSeparatedByString:@"-"];
    NSMutableArray<NSString *> *cleanParts = [NSMutableArray array];
    for (NSString *part in parts) {
        NSString *clean = [self normalizedLicenseText:part];
        if (clean.length > 0) {
            [cleanParts addObject:clean];
        }
    }

    NSString *prefix = nil;
    NSString *expiry = nil;
    NSMutableString *signature = [NSMutableString string];

    if (cleanParts.count >= 2) {
        NSString *first = cleanParts[0];
        if ([first isEqualToString:@"PERM"]) {
            prefix = @"YP";
            expiry = @"PERM";
            for (NSUInteger i = 1; i < cleanParts.count; i++) {
                [signature appendString:cleanParts[i]];
            }
        } else if ([self isCompactDateString:first]) {
            prefix = @"Y1";
            expiry = first;
            for (NSUInteger i = 1; i < cleanParts.count; i++) {
                [signature appendString:cleanParts[i]];
            }
        }
    }

    if (!prefix) {
        NSString *compact = [self normalizedLicenseText:upper];
        if (compact.length >= 20 && [compact hasPrefix:@"PERM"]) {
            prefix = @"YP";
            expiry = @"PERM";
            [signature appendString:[compact substringFromIndex:4]];
        } else if (compact.length >= 24) {
            NSString *date = [compact substringToIndex:8];
            if ([self isCompactDateString:date]) {
                prefix = @"Y1";
                expiry = date;
                [signature appendString:[compact substringFromIndex:8]];
            }
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

- (BOOL)isCompactDateString:(NSString *)value {
    if (value.length != 8) {
        return NO;
    }
    return [value rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
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

    for (NSString *device in [self deviceCodeCandidatesForSigning]) {
        NSString *expected = [self expectedSignatureForSigningDevice:device prefix:license.prefix expiry:license.expiry];
        if ([license.signature isEqualToString:expected]) {
            return YES;
        }
    }

    return NO;
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

- (NSString *)expectedSignatureForDevice:(NSString *)deviceCode prefix:(NSString *)prefix expiry:(NSString *)expiry {
    NSString *device = [self normalizedDeviceCodeForSigning:deviceCode];
    return [self expectedSignatureForSigningDevice:device prefix:prefix expiry:expiry];
}

- (NSString *)expectedSignatureForSigningDevice:(NSString *)device prefix:(NSString *)prefix expiry:(NSString *)expiry {
    NSString *message = [NSString stringWithFormat:@"VCAM|v2|%@|%@|%@", device, prefix, expiry];
    NSData *digest = [self hmacSHA256DataForMessage:message];
    return [self safeSignatureFromDigest:digest length:16];
}

- (NSArray<NSString *> *)deviceCodeCandidatesForSigning {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    [self addDeviceCodeCandidate:gVCamCachedDeviceCode toArray:candidates seen:seen];
    [self addDeviceCodeCandidate:[self rawDeviceCode] toArray:candidates seen:seen];
    [self addDeviceCodeCandidate:[NSString stringWithContentsOfFile:kVCamDevicePath encoding:NSUTF8StringEncoding error:nil] toArray:candidates seen:seen];

    return candidates;
}

- (void)addDeviceCodeCandidate:(NSString *)deviceCode toArray:(NSMutableArray<NSString *> *)array seen:(NSMutableSet<NSString *> *)seen {
    NSString *normalized = [self normalizedDeviceCodeForSigning:deviceCode];
    if (normalized.length < 16 || [seen containsObject:normalized]) {
        return;
    }

    [seen addObject:normalized];
    [array addObject:normalized];
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
    NSString *head = [license.prefix isEqualToString:@"YP"] ? @"PERM" : license.expiry;
    return [NSString stringWithFormat:@"%@-%@", head, [sigParts componentsJoinedByString:@"-"]];
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

- (NSString *)normalizedDeviceCodeForSigning:(NSString *)text {
    return [self normalizedLicenseText:text];
}

@end
