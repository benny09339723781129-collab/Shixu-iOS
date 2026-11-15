#import "SXMarketSourceChecks.h"
#import "SXMarketData.h"
#import <math.h>

#if DEBUG
static BOOL SXSmokeNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}

static BOOL SXSmokeDay(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 10) return NO;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{4}-[0-9]{2}-[0-9]{2}$" options:0 error:nil];
    if ([pattern numberOfMatchesInString:value options:0 range:NSMakeRange(0,[value length])] != 1) return NO;
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    format.dateFormat = @"yyyy-MM-dd"; format.lenient = NO;
    NSDate *date = [format dateFromString:value];
    return date != nil && [[format stringFromDate:date] isEqualToString:value];
}

static BOOL SXSmokeBar(id value) {
    if (![value isKindOfClass:NSDictionary.class] || !SXSmokeDay(value[@"time"])) return NO;
    for (NSString *key in @[@"open",@"high",@"low",@"close",@"volume"]) if (!SXSmokeNumber(value[key])) return NO;
    double open = [value[@"open"] doubleValue], high = [value[@"high"] doubleValue];
    double low = [value[@"low"] doubleValue], close = [value[@"close"] doubleValue];
    return open > 0 && close > 0 && low > 0 && high >= MAX(open,close) &&
        low <= MIN(open,close) && [value[@"volume"] doubleValue] >= 0;
}

@interface SXMarketSourceSmoke : NSObject
@property(nonatomic,strong) dispatch_group_t group;
@property(nonatomic,strong) NSMutableSet<NSString *> *completed;
@property(nonatomic,strong) NSMutableArray<NSString *> *failures;
@property(nonatomic,strong) NSMutableDictionary *providers;
@property(nonatomic,strong) NSMutableDictionary *currencies;
@property(nonatomic,strong) NSMutableDictionary *historyCounts;
@property(nonatomic,strong) NSMutableDictionary *lastDays;
@property(nonatomic,copy) NSString *runID;
@property(nonatomic,copy) NSString *startedAt;
@property(nonatomic) BOOL finished;
- (void)start;
- (void)accept:(NSDictionary *)value error:(NSError *)error code:(NSString *)code kind:(NSString *)kind;
- (void)finish:(BOOL)timedOut;
@end

static SXMarketSourceSmoke *SXActiveMarketSmoke;

@implementation SXMarketSourceSmoke
- (void)start {
    self.group = dispatch_group_create(); self.completed = [NSMutableSet new];
    self.failures = [NSMutableArray new]; self.providers = [NSMutableDictionary new];
    self.currencies = [NSMutableDictionary new]; self.historyCounts = [NSMutableDictionary new];
    self.lastDays = [NSMutableDictionary new];
    self.startedAt = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger argumentIndex = [arguments indexOfObject:@"--market-source-smoke-id"];
    NSString *candidate = argumentIndex != NSNotFound && argumentIndex + 1 < arguments.count ? arguments[argumentIndex+1] : nil;
    self.runID = candidate && [[NSUUID alloc] initWithUUIDString:candidate] ? candidate : NSUUID.UUID.UUIDString;

    // Four logical API calls only. SXMarketData may issue monthly exchange HTTP
    // requests internally; this check neither adds retries nor calls research APIs.
    for (NSString *code in @[@"AMD",@"2330"]) {
        self.providers[code] = [@{@"quote":NSNull.null,@"history":NSNull.null} mutableCopy];
        self.currencies[code] = [@{@"quote":NSNull.null,@"history":NSNull.null} mutableCopy];
        self.historyCounts[code] = @0; self.lastDays[code] = NSNull.null;
        dispatch_group_enter(self.group);
        [[SXMarketData shared] quoteForCode:code completion:^(NSDictionary *value,NSError *error) {
            [self accept:value error:error code:code kind:@"quote"];
        }];
        dispatch_group_enter(self.group);
        [[SXMarketData shared] historyForCode:code completion:^(NSDictionary *value,NSError *error) {
            [self accept:value error:error code:code kind:@"history"];
        }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(self.group,dispatch_get_main_queue(), ^{ [weakSelf finish:NO]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,125 * NSEC_PER_SEC),dispatch_get_main_queue(), ^{ [weakSelf finish:YES]; });
}

- (void)accept:(NSDictionary *)value error:(NSError *)error code:(NSString *)code kind:(NSString *)kind {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self accept:value error:error code:code kind:kind]; });
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@.%@",code,kind];
    if ([self.completed containsObject:key]) return;
    [self.completed addObject:key];
    if (!self.finished) {
        NSDictionary *data = [value isKindOfClass:NSDictionary.class] ? value : @{};
        NSString *source = [data[@"source"] isKindOfClass:NSString.class] ? data[@"source"] : nil;
        NSString *currency = [data[@"currency"] isKindOfClass:NSString.class] ? data[@"currency"] : nil;
        self.providers[code][kind] = source ?: NSNull.null;
        self.currencies[code][kind] = currency ?: NSNull.null;
        NSString *expectedSource = [code isEqualToString:@"AMD"] ? @"Nasdaq" : @"TWSE";
        NSString *expectedCurrency = [code isEqualToString:@"AMD"] ? @"USD" : @"TWD";
        if (error || !data.count) [self.failures addObject:[key stringByAppendingString:@": public provider request failed"]];
        if (![source isEqualToString:expectedSource]) [self.failures addObject:[key stringByAppendingString:@": unexpected or missing provider"]];
        if (![currency isEqualToString:expectedCurrency]) [self.failures addObject:[key stringByAppendingString:@": unexpected or missing currency"]];
        if ([kind isEqualToString:@"quote"]) {
            NSString *symbol = [code isEqualToString:@"AMD"] ? @"AMD" : @"2330.TW";
            if (![data[@"symbol"] isEqual:symbol]) [self.failures addObject:[key stringByAppendingString:@": symbol mismatch"]];
            if (!SXSmokeNumber(data[@"price"]) || [data[@"price"] doubleValue] <= 0)
                [self.failures addObject:[key stringByAppendingString:@": no finite positive quote"]];
        } else {
            NSArray *rows = [data[@"rows"] isKindOfClass:NSArray.class] ? data[@"rows"] : @[];
            self.historyCounts[code] = @(rows.count);
            id last = rows.lastObject; id lastDay = [last isKindOfClass:NSDictionary.class] ? last[@"time"] : nil;
            self.lastDays[code] = [lastDay isKindOfClass:NSString.class] ? lastDay : NSNull.null;
            if (rows.count < 50) [self.failures addObject:[key stringByAppendingString:@": fewer than 50 historical rows"]];
            BOOL valid = YES; NSString *previous = nil;
            for (id row in rows) {
                if (!SXSmokeBar(row)) { valid = NO; break; }
                NSString *day = row[@"time"];
                if (previous && [previous compare:day] != NSOrderedAscending) { valid = NO; break; }
                previous = day;
            }
            if (!valid) [self.failures addObject:[key stringByAppendingString:@": invalid OHLC/date or duplicate/unordered day"]];
            if (!SXSmokeDay(lastDay)) [self.failures addObject:[key stringByAppendingString:@": invalid last trading day"]];
        }
    }
    dispatch_group_leave(self.group);
}

- (void)finish:(BOOL)timedOut {
    if (self.finished) return;
    self.finished = YES;
    if (timedOut) for (NSString *code in @[@"AMD",@"2330"]) for (NSString *kind in @[@"quote",@"history"]) {
        NSString *key = [NSString stringWithFormat:@"%@.%@",code,kind];
        if (![self.completed containsObject:key]) [self.failures addObject:[key stringByAppendingString:@": did not complete within 125 seconds"]];
    }
    NSDictionary *report = @{@"passed":@(self.failures.count==0 && self.completed.count==4),
        @"failures":[self.failures copy], @"provider":self.providers, @"currency":self.currencies,
        @"historyRows":self.historyCounts, @"lastDay":self.lastDays, @"logicalRequests":@4,
        @"completedRequests":@(self.completed.count), @"debug":@YES, @"fixtureMode":@NO,
        @"runID":self.runID, @"startedAt":self.startedAt,
        @"finishedAt":[[NSISO8601DateFormatter new] stringFromDate:NSDate.date]};
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    [bytes writeToURL:[directory URLByAppendingPathComponent:@"market-provider-smoke.json"]
             options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    if (SXActiveMarketSmoke == self) SXActiveMarketSmoke = nil;
}
@end
#endif

void SXRunMarketSourceChecks(void) {
#if DEBUG
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ SXRunMarketSourceChecks(); }); return; }
    NSArray *arguments = NSProcessInfo.processInfo.arguments;
    if (![arguments containsObject:@"--market-source-smoke"] || [arguments containsObject:@"--ui-fixtures"] || SXActiveMarketSmoke) return;
    static BOOL started;
    if (started) return;
    started = YES;
    SXActiveMarketSmoke = [SXMarketSourceSmoke new];
    [SXActiveMarketSmoke start];
#endif
}
