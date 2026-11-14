#import "SXStore.h"
#import "SXAPI.h"
#import <math.h>
NSNotificationName const SXStoreDidChangeNotification=@"SXStoreDidChange";
NSNotificationName const SXQuotesDidChangeNotification=@"SXQuotesDidChange";
static BOOL Finite(id value){return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&isfinite([value doubleValue]);}
static NSSet *ProfileKeys(void){return [NSSet setWithArray:@[@"settings",@"watch",@"holdings",@"alerts",@"savedArticles",@"runs",@"account.v1",@"account.currency",@"market.cards.US",@"market.cards.TW",@"chart.averages",@"nexa.plans",@"nexa.requests",@"intel.bookmarks",@"dark-preference.v3"]];}
static BOOL Text(id value){return [value isKindOfClass:NSString.class]&&[value length]>0;}
static BOOL ValidValues(id values){
 if(![values isKindOfClass:NSDictionary.class]||[values count]>2000)return NO;
 NSSet *lists=[NSSet setWithArray:@[@"watch",@"holdings",@"alerts",@"savedArticles",@"runs",@"chart.averages",@"intel.bookmarks",@"market.cards.US",@"market.cards.TW"]],*objects=[NSSet setWithArray:@[@"settings",@"account.v1",@"nexa.plans",@"nexa.requests"]];
 NSRegularExpression *notes=[NSRegularExpression regularExpressionWithPattern:@"^note\\.[A-Z0-9.\\-]{1,16}$" options:0 error:nil];
 for(id key in values){if(![key isKindOfClass:NSString.class])return NO;id value=values[key];BOOL note=[notes firstMatchInString:key options:0 range:NSMakeRange(0,[key length])]!=nil;if(![ProfileKeys() containsObject:key]&&!note)return NO;if(note&&![value isKindOfClass:NSString.class])return NO;if([lists containsObject:key]&&![value isKindOfClass:NSArray.class])return NO;if([objects containsObject:key]&&![value isKindOfClass:NSDictionary.class])return NO;}
 id account=values[@"account.v1"];if(account){if(![account[@"cash"] isKindOfClass:NSArray.class]||![account[@"positions"] isKindOfClass:NSArray.class])return NO;
  NSMutableSet *cashIDs=[NSMutableSet new],*positionIDs=[NSMutableSet new];
  for(id row in account[@"cash"]){if(![row isKindOfClass:NSDictionary.class]||!Text(row[@"id"])||[cashIDs containsObject:row[@"id"]]||!Finite(row[@"amount"])||fabs([row[@"amount"] doubleValue])>1e15||![@[@"USD",@"TWD"] containsObject:row[@"currency"]?:@""]||!Text(row[@"date"]))return NO;[cashIDs addObject:row[@"id"]];}
  for(id row in account[@"positions"]){if(![row isKindOfClass:NSDictionary.class]||!Text(row[@"id"])||[positionIDs containsObject:row[@"id"]]||!Text(row[@"code"])||!Finite(row[@"quantity"])||[row[@"quantity"] doubleValue]<=0||[row[@"quantity"] doubleValue]>1e15||!Finite(row[@"cost"])||[row[@"cost"] doubleValue]<=0||[row[@"cost"] doubleValue]>1e15||![@[@"USD",@"TWD"] containsObject:row[@"currency"]?:@""])return NO;[positionIDs addObject:row[@"id"]];}
 }
 for(id row in values[@"runs"]?:@[])if(![row isKindOfClass:NSDictionary.class]||!Text(row[@"id"])||!Text(row[@"code"]))return NO;
 for(id code in values[@"watch"]?:@[])if(!Text(code))return NO;
 if(values[@"account.currency"]&&![@[@"USD",@"TWD"] containsObject:values[@"account.currency"]])return NO;
 return YES;
}
@interface SXStore ()
@property(nonatomic,strong) NSMutableDictionary *values;
@property(nonatomic,strong) NSMutableDictionary *quoteValues;
@property(nonatomic,strong) NSMutableSet *quoteFailures;
@property(nonatomic,strong) NSMutableSet *loadingCodes;
@property(nonatomic,strong) NSDictionary *stocks;
@property(nonatomic,strong) NSURL *profileURL;
@property(nonatomic,readwrite) NSArray *directory;
@property(nonatomic,readwrite) NSString *persistenceError;
@property(nonatomic,strong) NSError *lastWriteError;
@end
@implementation SXStore
+ (instancetype)sharedStore {static SXStore *store;static dispatch_once_t once;dispatch_once(&once,^{store=[SXStore new];});return store;}
- (instancetype)init {
 if((self=[super init])){
  self.values=[NSMutableDictionary new];self.quoteValues=[NSMutableDictionary new];self.quoteFailures=[NSMutableSet new];self.loadingCodes=[NSMutableSet new];
  NSURL *base=[[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"ShixuNative" isDirectory:YES];
  [NSFileManager.defaultManager createDirectoryAtURL:base withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];self.profileURL=[base URLByAppendingPathComponent:@"profile-v1.json"];
  NSData *data=[NSData dataWithContentsOfURL:self.profileURL];NSDictionary *profile=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
  if([profile isKindOfClass:NSDictionary.class]&&[profile[@"version"] isEqual:@1]&&ValidValues(profile[@"values"]))self.values=[profile[@"values"] mutableCopy];
  else if(data.length)self.persistenceError=@"原生紀錄暫時無法讀取，請先匯出或還原備份；原檔仍保留。";
  NSData *directoryData=[NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"Directory" ofType:@"json"]?:@""];
  id directory=directoryData?[NSJSONSerialization JSONObjectWithData:directoryData options:0 error:nil]:nil;self.directory=[directory isKindOfClass:NSArray.class]?directory:@[];
  NSMutableDictionary *stocks=[NSMutableDictionary new];for(NSDictionary *stock in self.directory)if([stock[@"code"] isKindOfClass:NSString.class])stocks[stock[@"code"]]=stock;self.stocks=stocks;
#if DEBUG
  if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]){NSDictionary *fixture=[NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"FixtureProfile" ofType:@"plist"]];if(fixture)self.values=[fixture mutableCopy];}
#endif
 }return self;
}
- (NSDictionary *)profile{return [self.values copy];}
- (NSDictionary *)account {id account=self.values[@"account.v1"];return [account isKindOfClass:NSDictionary.class]?account:@{@"cash":@[],@"positions":@[]};}
- (NSArray *)runs {id runs=self.values[@"runs"];if(![runs isKindOfClass:NSArray.class])return @[];return [runs filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id run,NSDictionary *bindings){return [run isKindOfClass:NSDictionary.class]&&[run[@"id"] isKindOfClass:NSString.class]&&[run[@"code"] isKindOfClass:NSString.class];}]];}
- (NSArray *)watchCodes {id codes=self.values[@"watch"];if(![codes isKindOfClass:NSArray.class])return @[];return [codes filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id code,NSDictionary *bindings){return [code isKindOfClass:NSString.class];}]];}
- (NSDictionary *)quotes{return [self.quoteValues copy];}
- (NSSet *)quoteErrors{return [self.quoteFailures copy];}
- (id)valueForProfileKey:(NSString *)key fallback:(id)fallback {id value=self.values[key];return value&&value!=NSNull.null?value:fallback;}
- (id)setting:(NSString *)key fallback:(id)fallback {id settings=self.values[@"settings"];id value=[settings isKindOfClass:NSDictionary.class]?settings[key]:nil;return value&&value!=NSNull.null?value:fallback;}
- (BOOL)persist {
 if(self.persistenceError)return NO;
#if DEBUG
 if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]){[NSNotificationCenter.defaultCenter postNotificationName:SXStoreDidChangeNotification object:self];return YES;}
#endif
 NSError *error=nil;NSData *data=[self exportProfileData:&error];if(!data||![data writeToURL:self.profileURL options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&error]){self.lastWriteError=error;self.persistenceError=error.localizedDescription?:@"無法儲存這次修改，請先匯出資料保留副本。";return NO;}self.lastWriteError=nil;[NSNotificationCenter.defaultCenter postNotificationName:SXStoreDidChangeNotification object:self];return YES;
}
- (BOOL)setProfileValue:(id)value forKey:(NSString *)key {if(!value||![NSJSONSerialization isValidJSONObject:@{key:value}])return NO;NSMutableDictionary *candidate=[self.values mutableCopy];candidate[key]=value;if(!ValidValues(candidate))return NO;id previous=self.values[key];self.values[key]=value;if([self persist])return YES;if(previous)self.values[key]=previous;else [self.values removeObjectForKey:key];return NO;}
- (BOOL)setSetting:(id)value forKey:(NSString *)key {NSMutableDictionary *settings=[[self valueForProfileKey:@"settings" fallback:@{}] mutableCopy];settings[key]=value;return [self setProfileValue:settings forKey:@"settings"];}
- (BOOL)saveAccount:(NSDictionary *)account {if(![account[@"cash"] isKindOfClass:NSArray.class]||![account[@"positions"] isKindOfClass:NSArray.class])return NO;return [self setProfileValue:account forKey:@"account.v1"];}
- (void)upsertRun:(NSDictionary *)run {if(![run[@"id"] isKindOfClass:NSString.class]||![run[@"code"] isKindOfClass:NSString.class])return;NSMutableArray *runs=[self.runs mutableCopy];NSUInteger index=[runs indexOfObjectPassingTest:^BOOL(NSDictionary *row,NSUInteger i,BOOL *stop){return [row[@"id"] isEqual:run[@"id"]];}];if(index!=NSNotFound){NSDictionary *previous=runs[index];if([previous[@"status"] isEqual:@"completed"]&&[previous[@"result"] isKindOfClass:NSDictionary.class])return;NSMutableDictionary *merged=[previous mutableCopy];[merged addEntriesFromDictionary:run];runs[index]=merged;}else [runs insertObject:run atIndex:0];[self setProfileValue:runs forKey:@"runs"];}
- (BOOL)isPinned:(NSString *)runID {id pins=[self setting:@"researchPins" fallback:@[]];return [pins isKindOfClass:NSArray.class]&&[pins containsObject:runID];}
- (void)togglePin:(NSString *)runID {id saved=[self setting:@"researchPins" fallback:@[]];NSMutableArray *pins=[saved isKindOfClass:NSArray.class]?[saved mutableCopy]:[NSMutableArray new];if([pins containsObject:runID])[pins removeObject:runID];else [pins addObject:runID];[self setSetting:pins forKey:@"researchPins"];}
- (void)setWatchCodes:(NSArray *)codes {[self setProfileValue:[[NSOrderedSet orderedSetWithArray:codes] array] forKey:@"watch"];}
- (NSDictionary *)stockForCode:(NSString *)code {return self.stocks[code.uppercaseString];}
- (NSString *)sourceSymbolForCode:(NSString *)code {NSDictionary *stock=[self stockForCode:code];return [stock[@"market"] isEqual:@"TW"]?[code stringByAppendingString:[stock[@"exchange"] isEqual:@"上櫃"]?@".TWO":@".TW"]:[code stringByReplacingOccurrencesOfString:@"." withString:@"-"];}
- (void)refreshQuotesForCodes:(NSArray *)codes completion:(void (^)(void))completion {
 NSMutableArray *pending=[NSMutableArray new];for(NSString *code in [NSOrderedSet orderedSetWithArray:codes])if([self stockForCode:code]&&![self.loadingCodes containsObject:code]){[pending addObject:code];[self.loadingCodes addObject:code];}
 if(!pending.count){if(completion)completion();return;}__block NSUInteger remaining=pending.count;
 for(NSString *code in pending){NSString *path=[@"/api/quote?symbol=" stringByAppendingString:[[self sourceSymbolForCode:code] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];[[SXAPI sharedAPI] requestPath:path method:@"GET" body:nil completion:^(id json,NSInteger status,NSError *error){NSString *currency=[[self stockForCode:code][@"market"] isEqual:@"TW"]?@"TWD":@"USD";if(!error&&[json isKindOfClass:NSDictionary.class]&&Finite(json[@"price"])&&[json[@"price"] doubleValue]>0&&[json[@"currency"] isEqual:currency]){self.quoteValues[code]=json;[self.quoteFailures removeObject:code];}else [self.quoteFailures addObject:code];[self.loadingCodes removeObject:code];[NSNotificationCenter.defaultCenter postNotificationName:SXQuotesDidChangeNotification object:self];if(--remaining==0&&completion)completion();}];}
}
- (NSData *)exportProfileData:(NSError **)error {return [NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"values":self.values} options:NSJSONWritingSortedKeys error:error];}
- (BOOL)importProfile:(NSDictionary *)profile replace:(BOOL)replace error:(NSError **)error {
 BOOL valid=[profile isKindOfClass:NSDictionary.class]&&[profile[@"version"] isEqual:@1]&&ValidValues(profile[@"values"]);NSDictionary *values=valid?profile[@"values"]:@{};
 NSRegularExpression *note=[NSRegularExpression regularExpressionWithPattern:@"^note\\.[A-Z0-9.\\-]{1,16}$" options:0 error:nil];
 for(NSString *key in values){if(![key isKindOfClass:NSString.class]||(![ProfileKeys() containsObject:key]&&![note firstMatchInString:key options:0 range:NSMakeRange(0,key.length)]))valid=NO;}
 NSData *bytes=valid?[NSJSONSerialization dataWithJSONObject:profile options:0 error:nil]:nil;if(bytes.length>8*1024*1024||!bytes)valid=NO;
 if(!valid){if(error)*error=[NSError errorWithDomain:@"SXStore" code:1 userInfo:@{NSLocalizedDescriptionKey:@"備份格式不正確，原有資料仍保留。"}];return NO;}
 if(!replace&&[self hasPersonalData]){if(error)*error=[NSError errorWithDomain:@"SXStore" code:2 userInfo:@{NSLocalizedDescriptionKey:@"已有原生紀錄，請先匯出，再明確選擇要還原的版本。"}];return NO;}
 if([NSFileManager.defaultManager fileExistsAtPath:self.profileURL.path]){NSURL *copy=[self.profileURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@"before-import-%@.json",NSUUID.UUID.UUIDString]];if(![NSFileManager.defaultManager copyItemAtURL:self.profileURL toURL:copy error:error])return NO;}
 NSMutableDictionary *before=self.values;NSString *previousError=self.persistenceError;NSError *previousWriteError=self.lastWriteError;
 self.values=[values mutableCopy];self.persistenceError=nil;self.lastWriteError=nil;
 if([self persist])return YES;
 NSString *writeMessage=self.persistenceError?:@"無法儲存還原資料。";NSError *writeError=self.lastWriteError;
 self.values=before;self.persistenceError=previousError?:writeMessage;self.lastWriteError=previousWriteError?:writeError;
 if(error){NSMutableDictionary *details=[@{NSLocalizedDescriptionKey:writeMessage} mutableCopy];if(writeError)details[NSUnderlyingErrorKey]=writeError;*error=[NSError errorWithDomain:@"SXStore" code:3 userInfo:details];}return NO;
}
- (BOOL)hasPersonalData {return self.runs.count||self.watchCodes.count||[self.account[@"positions"] count]||[self.account[@"cash"] count]||[[self.values.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'note.'"]] count];}
@end
