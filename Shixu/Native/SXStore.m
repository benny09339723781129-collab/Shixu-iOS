#import "SXStore.h"
#import "SXMarketData.h"
#import "SXAPI.h"
#import <math.h>
#import <CommonCrypto/CommonDigest.h>
NSNotificationName const SXStoreDidChangeNotification=@"SXStoreDidChange";
NSNotificationName const SXQuotesDidChangeNotification=@"SXQuotesDidChange";
static BOOL Finite(id value){return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&isfinite([value doubleValue]);}
static NSSet *ProfileKeys(void){return [NSSet setWithArray:@[@"settings",@"watch",@"holdings",@"alerts",@"savedArticles",@"runs",@"account.v1",@"account.currency",@"market.cards.US",@"market.cards.TW",@"chart.averages",@"nexa.plans",@"nexa.requests",@"intel.bookmarks",@"dark-preference.v3"]];}
static BOOL Text(id value){return [value isKindOfClass:NSString.class]&&[value length]>0;}
static NSString *ProfileFilename(NSString *userID){if(!userID)return @"profile-v1.json";NSData *data=[userID dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *hash=[NSMutableString new];for(NSUInteger i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hash appendFormat:@"%02x",digest[i]];return [NSString stringWithFormat:@"account-%@.json",hash];}
static NSError *WorkspaceError(NSString *message){return [NSError errorWithDomain:@"SXWorkspace" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
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
@property(nonatomic,strong) NSURL *profileDirectoryURL;
@property(nonatomic,readwrite,copy) NSString *activeProfileUserID;
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
  [NSFileManager.defaultManager createDirectoryAtURL:base withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];self.profileDirectoryURL=base;
  id active=[NSUserDefaults.standardUserDefaults objectForKey:@"native-active-profile-user-v1"];self.activeProfileUserID=Text(active)?active:nil;
#if DEBUG
  if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"])self.activeProfileUserID=nil;
#endif
  self.profileURL=[base URLByAppendingPathComponent:ProfileFilename(self.activeProfileUserID)];
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
- (BOOL)activateProfileForUserID:(NSString *)userID error:(NSError **)error {
 if(userID&&(!Text(userID)||userID.length>1024)){if(error)*error=WorkspaceError(@"帳號身分無法驗證，未切換資料。");return NO;}
 if((!userID&&!self.activeProfileUserID)||[userID isEqual:self.activeProfileUserID])return YES;
 if(![self persist]){if(error)*error=self.lastWriteError?:WorkspaceError(self.persistenceError?:@"目前資料無法保存，未切換帳號。");return NO;}
 NSURL *target=[self.profileDirectoryURL URLByAppendingPathComponent:ProfileFilename(userID)];NSMutableDictionary *next=[NSMutableDictionary new];
 if([NSFileManager.defaultManager fileExistsAtPath:target.path]){NSError *readError=nil;NSData *data=[NSData dataWithContentsOfURL:target options:0 error:&readError];id profile=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:&readError]:nil;if(readError||![profile isKindOfClass:NSDictionary.class]||![profile[@"version"] isEqual:@1]||!ValidValues(profile[@"values"])){if(error)*error=readError?:WorkspaceError(@"此帳號的本機工作區無法讀取，原有工作區與檔案保留。");return NO;}next=[profile[@"values"] mutableCopy];}
 else {NSError *writeError=nil;NSData *empty=[NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"values":@{}} options:NSJSONWritingSortedKeys error:&writeError];if(!empty||![empty writeToURL:target options:NSDataWritingAtomic|NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&writeError]){if(error)*error=writeError?:WorkspaceError(@"無法建立帳號工作區，原有資料保留。");return NO;}}
 self.values=next;self.profileURL=target;self.activeProfileUserID=userID;self.persistenceError=nil;self.lastWriteError=nil;
#if DEBUG
 if(![NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"])
#endif
 {if(userID)[NSUserDefaults.standardUserDefaults setObject:userID forKey:@"native-active-profile-user-v1"];else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"native-active-profile-user-v1"];}
 [NSNotificationCenter.defaultCenter postNotificationName:SXStoreDidChangeNotification object:self userInfo:@{@"workspaceChanged":@YES}];return YES;
}
- (BOOL)copyLocalProfileToActiveAccount:(NSError **)error {
 if(!self.activeProfileUserID||self.values.count||self.persistenceError){if(error)*error=WorkspaceError(@"只有可正常讀取的空白帳號工作區能複製本機資料；目前資料未變更。");return NO;}
 NSURL *local=[self.profileDirectoryURL URLByAppendingPathComponent:@"profile-v1.json"];NSData *data=[NSData dataWithContentsOfURL:local options:0 error:error];id profile=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:error]:nil;
 if(![profile isKindOfClass:NSDictionary.class]){if(error&&!*error)*error=WorkspaceError(@"未找到有效的未登入本機備份，原檔保留。");return NO;}return [self importProfile:profile replace:NO error:error];
}
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
- (BOOL)upsertRun:(NSDictionary *)run {if(![run isKindOfClass:NSDictionary.class]||!Text(run[@"id"])||!Text(run[@"code"]))return NO;NSMutableArray *runs=[self.runs mutableCopy];NSUInteger index=[runs indexOfObjectPassingTest:^BOOL(NSDictionary *row,NSUInteger i,BOOL *stop){return [row[@"id"] isEqual:run[@"id"]];}];if(index!=NSNotFound){NSDictionary *previous=runs[index];if([previous[@"status"] isEqual:@"completed"]&&[previous[@"result"] isKindOfClass:NSDictionary.class])return [run[@"status"] isEqual:@"completed"]&&[run[@"code"] isEqual:previous[@"code"]]&&[run[@"result"] isEqual:previous[@"result"]];NSMutableDictionary *merged=[previous mutableCopy];[merged addEntriesFromDictionary:run];runs[index]=merged;}else [runs insertObject:run atIndex:0];return [self setProfileValue:runs forKey:@"runs"];}
- (BOOL)isPinned:(NSString *)runID {id pins=[self setting:@"researchPins" fallback:@[]];return [pins isKindOfClass:NSArray.class]&&[pins containsObject:runID];}
- (void)togglePin:(NSString *)runID {id saved=[self setting:@"researchPins" fallback:@[]];NSMutableArray *pins=[saved isKindOfClass:NSArray.class]?[saved mutableCopy]:[NSMutableArray new];if([pins containsObject:runID])[pins removeObject:runID];else [pins addObject:runID];[self setSetting:pins forKey:@"researchPins"];}
- (void)setWatchCodes:(NSArray *)codes {[self setProfileValue:[[NSOrderedSet orderedSetWithArray:codes] array] forKey:@"watch"];}
- (NSDictionary *)stockForCode:(NSString *)code {return self.stocks[code.uppercaseString];}
- (NSString *)sourceSymbolForCode:(NSString *)code {NSDictionary *stock=[self stockForCode:code];return [stock[@"market"] isEqual:@"TW"]?[code stringByAppendingString:[stock[@"exchange"] isEqual:@"上櫃"]?@".TWO":@".TW"]:[code stringByReplacingOccurrencesOfString:@"." withString:@"-"];}
- (void)refreshQuotesForCodes:(NSArray *)codes completion:(void (^)(void))completion {
 NSMutableArray *pending=[NSMutableArray new];for(NSString *code in [NSOrderedSet orderedSetWithArray:codes])if([self stockForCode:code]&&![self.loadingCodes containsObject:code]){[pending addObject:code];[self.loadingCodes addObject:code];}
 if(!pending.count){if(completion)completion();return;}__block NSUInteger remaining=pending.count;
 for(NSString *code in pending){[[SXMarketData shared] quoteForCode:code completion:^(NSDictionary *json,NSError *error){NSString *currency=[[self stockForCode:code][@"market"] isEqual:@"TW"]?@"TWD":@"USD";if(!error&&[json isKindOfClass:NSDictionary.class]&&Finite(json[@"price"])&&[json[@"price"] doubleValue]>0&&[json[@"currency"] isEqual:currency]){self.quoteValues[code]=json;[self.quoteFailures removeObject:code];}else [self.quoteFailures addObject:code];[self.loadingCodes removeObject:code];[NSNotificationCenter.defaultCenter postNotificationName:SXQuotesDidChangeNotification object:self];if(--remaining==0&&completion)completion();}];}
}
- (NSData *)exportProfileData:(NSError **)error {return [NSJSONSerialization dataWithJSONObject:@{@"version":@1,@"values":self.values} options:NSJSONWritingSortedKeys error:error];}
- (BOOL)importProfile:(NSDictionary *)profile replace:(BOOL)replace error:(NSError **)error {
 BOOL valid=[profile isKindOfClass:NSDictionary.class]&&[profile[@"version"] isEqual:@1]&&ValidValues(profile[@"values"]);NSDictionary *values=valid?profile[@"values"]:@{};
 NSRegularExpression *note=[NSRegularExpression regularExpressionWithPattern:@"^note\\.[A-Z0-9.\\-]{1,16}$" options:0 error:nil];
 for(NSString *key in values){if(![key isKindOfClass:NSString.class]||(![ProfileKeys() containsObject:key]&&![note firstMatchInString:key options:0 range:NSMakeRange(0,key.length)]))valid=NO;}
 NSData *bytes=valid?[NSJSONSerialization dataWithJSONObject:profile options:0 error:nil]:nil;if(bytes.length>8*1024*1024||!bytes)valid=NO;
 if(!valid){if(error)*error=[NSError errorWithDomain:@"SXStore" code:1 userInfo:@{NSLocalizedDescriptionKey:@"備份格式不正確，原有資料仍保留。"}];return NO;}
 if(!replace&&[self hasPersonalData]){if(error)*error=[NSError errorWithDomain:@"SXStore" code:2 userInfo:@{NSLocalizedDescriptionKey:@"已有原生紀錄，請先匯出，再明確選擇要還原的版本。"}];return NO;}
 if([NSFileManager.defaultManager fileExistsAtPath:self.profileURL.path]){NSURL *copy=[self.profileURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@"before-import-%@-%@.json",self.profileURL.lastPathComponent.stringByDeletingPathExtension,NSUUID.UUID.UUIDString]];if(![NSFileManager.defaultManager copyItemAtURL:self.profileURL toURL:copy error:error])return NO;}
 NSMutableDictionary *before=self.values;NSString *previousError=self.persistenceError;NSError *previousWriteError=self.lastWriteError;
 self.values=[values mutableCopy];self.persistenceError=nil;self.lastWriteError=nil;
 if([self persist])return YES;
 NSString *writeMessage=self.persistenceError?:@"無法儲存還原資料。";NSError *writeError=self.lastWriteError;
 self.values=before;self.persistenceError=previousError?:writeMessage;self.lastWriteError=previousWriteError?:writeError;
 if(error){NSMutableDictionary *details=[@{NSLocalizedDescriptionKey:writeMessage} mutableCopy];if(writeError)details[NSUnderlyingErrorKey]=writeError;*error=[NSError errorWithDomain:@"SXStore" code:3 userInfo:details];}return NO;
}
- (BOOL)hasPersonalData {return self.runs.count||self.watchCodes.count||[self.account[@"positions"] count]||[self.account[@"cash"] count]||[[self.values.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH 'note.'"]] count];}
- (NSArray<NSURL *> *)restoreCopiesForActiveProfile {NSString *prefix=[NSString stringWithFormat:@"before-import-%@-",self.profileURL.lastPathComponent.stringByDeletingPathExtension];NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:self.profileURL.URLByDeletingLastPathComponent includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];NSMutableArray *copies=[NSMutableArray new];for(NSURL *url in files)if([url.lastPathComponent hasPrefix:prefix]&&[url.pathExtension isEqual:@"json"])[copies addObject:url];return [copies sortedArrayUsingComparator:^NSComparisonResult(NSURL *a,NSURL *b){NSDate *ad=nil,*bd=nil;[a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil];[b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];return [(bd?:NSDate.distantPast) compare:ad?:NSDate.distantPast];}];}
@end
