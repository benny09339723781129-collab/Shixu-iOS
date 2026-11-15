#import "SXMarketData.h"
#import "SXStore.h"
#import "SXUI.h"
#import <math.h>

static NSError *MarketError(void) { return [NSError errorWithDomain:@"SXMarketData" code:1 userInfo:@{NSLocalizedDescriptionKey:@"行情來源暫時無法取得，請稍後重試。"}]; }
static NSString *MarketText(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSNumber *MarketNumber(id value) {
    if (SXFiniteNumber(value)) return value;
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *text = [[value stringByReplacingOccurrencesOfString:@"," withString:@""] stringByReplacingOccurrencesOfString:@"$" withString:@""];
    text = [[text stringByReplacingOccurrencesOfString:@"%" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSScanner *scanner = [NSScanner scannerWithString:text]; double number;
    return [scanner scanDouble:&number] && scanner.isAtEnd && isfinite(number) ? @(number) : nil;
}
static BOOL MarketHost(NSString *host) { return [@[@"api.nasdaq.com", @"www.twse.com.tw", @"www.tpex.org.tw"] containsObject:host.lowercaseString]; }
static NSString *MarketDay(NSString *text, NSString *format) {
    NSDateFormatter *input = [NSDateFormatter new]; input.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; input.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; input.dateFormat = format; input.lenient = NO;
    NSDate *date = [input dateFromString:text]; if (!date) return nil;
    input.dateFormat = @"yyyy-MM-dd"; return [input stringFromDate:date];
}
static NSDictionary *MarketBar(NSString *date, id open, id high, id low, id close, id volume) {
    NSNumber *o=MarketNumber(open), *h=MarketNumber(high), *l=MarketNumber(low), *c=MarketNumber(close), *v=MarketNumber(volume);
    if (!date || o.doubleValue<=0 || c.doubleValue<=0 || l.doubleValue<=0 || h.doubleValue<MAX(o.doubleValue,c.doubleValue) || l.doubleValue>MIN(o.doubleValue,c.doubleValue) || !v || v.doubleValue<0) return nil;
    return @{@"time":date, @"open":o, @"high":h, @"low":l, @"close":c, @"volume":v};
}
@interface SXMarketData ()
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSMutableDictionary *cache;
@end
@implementation SXMarketData
+ (instancetype)shared { static SXMarketData *data; static dispatch_once_t once; dispatch_once(&once, ^{data=[SXMarketData new];}); return data; }
- (instancetype)init {
    if ((self=[super init])) {
        self.cache=[NSMutableDictionary new]; NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.HTTPCookieStorage=nil; configuration.HTTPShouldSetCookies=NO; configuration.URLCache=nil; configuration.timeoutIntervalForRequest=12; configuration.timeoutIntervalForResource=18; configuration.HTTPMaximumConnectionsPerHost=2;
        self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    } return self;
}
- (void)get:(NSString *)address completion:(void (^)(id, NSError *))completion {
    NSURL *url=[NSURL URLWithString:address];
    if (![url.scheme isEqual:@"https"] || !MarketHost(url.host) || url.user || url.password) { completion(nil,MarketError()); return; }
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"]; [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *bytes,NSURLResponse *response,NSError *error){
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
        id json=!error && status==200 && MarketHost(response.URL.host) && bytes.length<8*1024*1024 ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{completion(json,json?nil:MarketError());});
    }] resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler { completionHandler(nil); }
+ (NSArray<NSDictionary *> *)nasdaqRows:(id)payload symbol:(NSString *)symbol {
    id data=[payload isKindOfClass:NSDictionary.class]?payload[@"data"]:nil;
    if (![data isKindOfClass:NSDictionary.class] || ![MarketText(data[@"symbol"]) isEqualToString:symbol]) return @[];
    id table=data[@"tradesTable"];
    id rows=[table isKindOfClass:NSDictionary.class]?table[@"rows"]:nil;
    if (![rows isKindOfClass:NSArray.class]) return @[];
    NSMutableDictionary *days=[NSMutableDictionary new];
    for (id row in rows) if ([row isKindOfClass:NSDictionary.class]) {
        NSDictionary *bar=MarketBar(MarketDay(MarketText(row[@"date"]),@"MM/dd/yyyy"),row[@"open"],row[@"high"],row[@"low"],row[@"close"],row[@"volume"]);
        if (bar) days[bar[@"time"]]=bar;
    }
    return [days.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"time"] compare:b[@"time"]];}];
}
+ (NSArray<NSDictionary *> *)taiwanRows:(id)payload code:(NSString *)code otc:(BOOL)otc {
    if (![payload isKindOfClass:NSDictionary.class]) return @[];
    NSDictionary *table=payload;
    if (otc) {id tables=payload[@"tables"]; if (![tables isKindOfClass:NSArray.class] || ![tables count]) return @[]; table=[tables firstObject];}
    NSString *title=MarketText(table[otc?@"subtitle":@"title"]);
    if (![title containsString:code] || (!otc && ![payload[@"stat"] isEqual:@"OK"]) || ![table[@"data"] isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *rows=[NSMutableArray new];
    for (id row in table[@"data"]) if ([row isKindOfClass:NSArray.class] && [row count]>=8) {
        NSArray *parts=[MarketText(row[0]) componentsSeparatedByString:@"/"];
        if (parts.count!=3) continue;
        NSString *date=MarketDay([NSString stringWithFormat:@"%ld-%02ld-%02ld",(long)[parts[0] integerValue]+1911,(long)[parts[1] integerValue],(long)[parts[2] integerValue]],@"yyyy-MM-dd");
        NSNumber *volume=MarketNumber(row[1]); if (otc && volume) volume=@(volume.doubleValue*1000); // TPEx publishes lots; chart uses shares.
        NSDictionary *bar=MarketBar(date,row[3],row[4],row[5],row[6],volume); if (bar) [rows addObject:bar];
    } return rows;
}
- (id)cached:(NSString *)key seconds:(double)seconds {
    NSDictionary *entry=self.cache[key]; return entry && [NSDate.date timeIntervalSince1970]-[entry[@"at"] doubleValue]<seconds ? entry[@"value"] : nil;
}
- (void)save:(id)value key:(NSString *)key { if(self.cache.count>150)[self.cache removeAllObjects];self.cache[key]=@{@"at":@(NSDate.date.timeIntervalSince1970),@"value":value}; }
- (BOOL)fixture:(NSString *)path completion:(SXMarketReply)completion {
#if DEBUG
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]) {
        NSDictionary *fixtures=[NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"FixtureAPI" ofType:@"plist"]];
        id value=fixtures[path]; dispatch_async(dispatch_get_main_queue(), ^{completion(value,value?nil:MarketError());}); return YES;
    }
#endif
    return NO;
}
- (void)month:(NSString *)code offset:(NSInteger)offset completion:(void (^)(NSArray *,NSError *))completion {
    NSString *key=[NSString stringWithFormat:@"month:%@:%ld",code,(long)offset]; id cached=[self cached:key seconds:300]; if(cached){completion(cached,nil);return;}
    NSDictionary *stock=[SXStore.sharedStore stockForCode:code]; BOOL otc=[stock[@"exchange"] isEqual:@"上櫃"];
    NSCalendar *calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian]; calendar.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Taipei"];
    NSDateComponents *parts=[calendar components:NSCalendarUnitYear|NSCalendarUnitMonth fromDate:NSDate.date]; parts.day=1;
    NSDate *date=[calendar dateByAddingUnit:NSCalendarUnitMonth value:-offset toDate:[calendar dateFromComponents:parts] options:0];
    NSDateFormatter *format=[NSDateFormatter new]; format.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; format.timeZone=calendar.timeZone; format.dateFormat=otc?@"yyyy/MM/dd":@"yyyyMMdd";
    NSString *address=otc?[NSString stringWithFormat:@"https://www.tpex.org.tw/www/zh-tw/afterTrading/tradingStock?code=%@&date=%@&response=json",code,[[format stringFromDate:date] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]]:[NSString stringWithFormat:@"https://www.twse.com.tw/exchangeReport/STOCK_DAY?response=json&date=%@&stockNo=%@",[format stringFromDate:date],code];
    [self get:address completion:^(id payload,NSError *error){NSArray *rows=[SXMarketData taiwanRows:payload code:code otc:otc];if(rows.count)[self save:rows key:key]; completion(rows,error);}];
}
- (void)quoteForCode:(NSString *)code completion:(SXMarketReply)completion {
    NSDictionary *stock=[SXStore.sharedStore stockForCode:code]; if(!stock){completion(nil,MarketError());return;}
    NSString *symbol=[SXStore.sharedStore sourceSymbolForCode:code];
    if([self fixture:[@"/api/quote?symbol=" stringByAppendingString:symbol] completion:completion])return;
    NSString *key=[@"quote:" stringByAppendingString:code]; id cached=[self cached:key seconds:60]; if(cached){completion(cached,nil);return;}
    if([stock[@"market"] isEqual:@"TW"]) {
        [self month:code offset:0 completion:^(NSArray *rows,NSError *error){
            void (^finish)(NSArray *)=^(NSArray *all){if(all.count<2){completion(nil,MarketError());return;}NSDictionary *last=all.lastObject,*prior=all[all.count-2];double price=[last[@"close"] doubleValue],previous=[prior[@"close"] doubleValue];NSDictionary *value=@{@"symbol":symbol,@"price":@(price),@"previousClose":@(previous),@"change":@(price-previous),@"changePercent":@((price/previous-1)*100),@"currency":@"TWD",@"marketDate":last[@"time"],@"timePrecision":@"date",@"source":[stock[@"exchange"] isEqual:@"上櫃"]?@"TPEx":@"TWSE",@"session":@"已收盤",@"fetchedAt":@([NSDate.date timeIntervalSince1970]*1000)};[self save:value key:key];completion(value,nil);};
            if(rows.count>=2)finish(rows);else [self month:code offset:1 completion:^(NSArray *previous,NSError *priorError){finish([previous arrayByAddingObjectsFromArray:rows?:@[]]);}];
        }]; return;
    }
    [self nasdaqQuote:code kind:[stock[@"kind"] isEqual:@"ETF"]?@"etf":@"stocks" retry:YES completion:^(NSDictionary *value,NSError *error){if(value)[self save:value key:key];completion(value,error);}];
}
- (void)nasdaqQuote:(NSString *)code kind:(NSString *)kind retry:(BOOL)retry completion:(SXMarketReply)completion {
    NSString *symbol=[code stringByReplacingOccurrencesOfString:@"." withString:@"-"];
    [self get:[NSString stringWithFormat:@"https://api.nasdaq.com/api/quote/%@/info?assetclass=%@",symbol,kind] completion:^(id payload,NSError *error){
        id data=[payload isKindOfClass:NSDictionary.class]?payload[@"data"]:nil;id primary=[data isKindOfClass:NSDictionary.class]?data[@"primaryData"]:nil;
        NSNumber *price=[primary isKindOfClass:NSDictionary.class]?MarketNumber(primary[@"lastSalePrice"]):nil;
        if(!price||price.doubleValue<=0||![MarketText(data[@"symbol"]) isEqual:symbol]) {if(retry)[self nasdaqQuote:code kind:[kind isEqual:@"etf"]?@"stocks":@"etf" retry:NO completion:completion];else completion(nil,MarketError());return;}
        NSNumber *change=MarketNumber(primary[@"netChange"]),*percent=MarketNumber(primary[@"percentageChange"]); NSString *stamp=MarketText(primary[@"lastTradeTimestamp"]);
        NSString *day=MarketDay(stamp,@"MMM d, yyyy");
        NSMutableDictionary *value=[@{@"symbol":code,@"price":price,@"change":change?:NSNull.null,@"changePercent":percent?:NSNull.null,@"currency":@"USD",@"source":@"Nasdaq",@"session":[data[@"marketStatus"] isEqual:@"Closed"]?@"已收盤":@"來源報價",@"marketDate":day?:stamp,@"timePrecision":day?@"date":@"source",@"fetchedAt":@([NSDate.date timeIntervalSince1970]*1000)} mutableCopy];
        if(change && price.doubleValue-change.doubleValue>0)value[@"previousClose"]=@(price.doubleValue-change.doubleValue);
        completion(value,nil);
    }];
}
- (void)historyForCode:(NSString *)code completion:(SXMarketReply)completion {
    NSDictionary *stock=[SXStore.sharedStore stockForCode:code]; if(!stock){completion(nil,MarketError());return;}
    NSString *symbol=[SXStore.sharedStore sourceSymbolForCode:code];
    if([self fixture:[NSString stringWithFormat:@"/api/chart?symbol=%@&interval=1d",symbol] completion:completion])return;
    NSString *key=[@"history:" stringByAppendingString:code];id cached=[self cached:key seconds:300];if(cached){completion(cached,nil);return;}
    if([stock[@"market"] isEqual:@"TW"]) {
        [self months:code offset:0 rows:[NSMutableArray new] failed:NO completion:^(NSArray *rows){if(!rows.count){completion(nil,MarketError());return;}NSDictionary *value=@{@"rows":rows,@"source":[stock[@"exchange"] isEqual:@"上櫃"]?@"TPEx":@"TWSE",@"currency":@"TWD"};[self save:value key:key];completion(value,nil);}];return;
    }
    NSDateFormatter *format=[NSDateFormatter new];format.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];format.timeZone=[NSTimeZone timeZoneWithName:@"America/New_York"];format.dateFormat=@"yyyy-MM-dd";
    NSString *start=[format stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-3*366*86400]],*end=[format stringFromDate:NSDate.date];NSString *kind=[stock[@"kind"] isEqual:@"ETF"]?@"etf":@"stocks";
    [self get:[NSString stringWithFormat:@"https://api.nasdaq.com/api/quote/%@/historical?assetclass=%@&fromdate=%@&todate=%@&limit=1000",code,kind,start,end] completion:^(id payload,NSError *error){NSArray *rows=[SXMarketData nasdaqRows:payload symbol:code];if(!rows.count){completion(nil,MarketError());return;}NSDictionary *value=@{@"rows":rows,@"source":@"Nasdaq",@"currency":@"USD"};[self save:value key:key];completion(value,nil);}];
}
- (void)months:(NSString *)code offset:(NSInteger)offset rows:(NSMutableArray *)rows failed:(BOOL)failed completion:(void (^)(NSArray *))completion {
    if(offset>=12){if(failed){completion(@[]);return;}NSMutableDictionary *days=[NSMutableDictionary new];for(NSDictionary *row in rows)days[row[@"time"]]=row;completion([days.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"time"] compare:b[@"time"]];}]);return;}
    dispatch_group_t group=dispatch_group_create();__block BOOL failedRequest=failed;
    for(NSInteger i=offset;i<offset+2;i++){dispatch_group_enter(group);[self month:code offset:i completion:^(NSArray *batch,NSError *error){if(error)failedRequest=YES;if(batch.count)[rows addObjectsFromArray:batch];dispatch_group_leave(group);}];}
    dispatch_group_notify(group,dispatch_get_main_queue(), ^{[self months:code offset:offset+2 rows:rows failed:failedRequest completion:completion];});
}
@end
