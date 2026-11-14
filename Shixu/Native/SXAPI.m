#import "SXAPI.h"
#import <WebKit/WebKit.h>

NSString *const SXOrigin=@"https://trend-forecast.pc-remote-worker.workers.dev";
@interface SXAPI ()
@property(nonatomic,strong) NSURLSession *session;
@end
@implementation SXAPI
+ (instancetype)sharedAPI { static SXAPI *api; static dispatch_once_t once; dispatch_once(&once,^{api=[SXAPI new];});return api; }
- (instancetype)init {
 if((self=[super init])){NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.defaultSessionConfiguration;configuration.HTTPCookieStorage=NSHTTPCookieStorage.sharedHTTPCookieStorage;configuration.HTTPShouldSetCookies=YES;configuration.URLCache=nil;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;configuration.HTTPMaximumConnectionsPerHost=4;configuration.timeoutIntervalForResource=300;self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];}return self;
}
- (void)requestPath:(NSString *)path method:(NSString *)method body:(id)body completion:(SXAPICompletion)completion {
 NSURL *url=[NSURL URLWithString:path relativeToURL:[NSURL URLWithString:SXOrigin]].absoluteURL;
 if(![path hasPrefix:@"/api/"]||[path hasPrefix:@"//"]||![url.host isEqualToString:[NSURL URLWithString:SXOrigin].host]||![url.scheme isEqualToString:@"https"]||url.user||url.password||url.fragment){dispatch_async(dispatch_get_main_queue(),^{completion(nil,0,[NSError errorWithDomain:@"SXAPI" code:1 userInfo:@{NSLocalizedDescriptionKey:@"無效的服務路徑。"}]);});return;}
#if DEBUG
 if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]){
  NSDictionary *fixtures=[NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"FixtureAPI" ofType:@"plist"]];
  id result=fixtures[path]?:fixtures[url.path];BOOL writable=![method isEqualToString:@"GET"];
  dispatch_async(dispatch_get_main_queue(),^{completion(writable?nil:result,writable?405:result?200:503,result&&!writable?nil:[NSError errorWithDomain:@"SXQA" code:1 userInfo:@{NSLocalizedDescriptionKey:@"隔離預覽不會呼叫正式後台。"}]);});return;
 }
#endif
 NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=method;request.timeoutInterval=[path hasPrefix:@"/api/account/"]?35:[method isEqualToString:@"POST"]?260:40;
 [request setValue:SXOrigin forHTTPHeaderField:@"Origin"];[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
 if(body){NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:body options:0 error:&error];if(!data){dispatch_async(dispatch_get_main_queue(),^{completion(nil,0,error);});return;}request.HTTPBody=data;[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];}
 [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *networkError){
  NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(id)response:nil;NSInteger status=http.statusCode;
  NSError *error=networkError;id json=nil;
  if(data.length>16*1024*1024)error=[NSError errorWithDomain:@"SXAPI" code:2 userInfo:@{NSLocalizedDescriptionKey:@"資料過大，請稍後重試。"}];
  else if(data.length)json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if(!error&&(status<200||status>=300||!json)){NSString *message=[json isKindOfClass:NSDictionary.class]&&[json[@"error"] isKindOfClass:NSString.class]?json[@"error"]:@"服務暫時無法回應，原有資料仍保留。";error=[NSError errorWithDomain:@"SXAPI" code:status userInfo:@{NSLocalizedDescriptionKey:message}];}
  if(!error&&[path isEqualToString:@"/api/account/sign-out"]){NSString *host=[NSURL URLWithString:SXOrigin].host;for(NSHTTPCookie *cookie in [NSHTTPCookieStorage.sharedHTTPCookieStorage cookiesForURL:[NSURL URLWithString:SXOrigin]])if([cookie.name hasPrefix:@"shiye_account."])[NSHTTPCookieStorage.sharedHTTPCookieStorage deleteCookie:cookie];[WKWebsiteDataStore.defaultDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies){dispatch_group_t group=dispatch_group_create();for(NSHTTPCookie *cookie in cookies)if([cookie.domain.lowercaseString isEqualToString:host]&&[cookie.name hasPrefix:@"shiye_account."]){dispatch_group_enter(group);[WKWebsiteDataStore.defaultDataStore.httpCookieStore deleteCookie:cookie completionHandler:^{dispatch_group_leave(group);}];}dispatch_group_notify(group,dispatch_get_main_queue(),^{completion(json,status,error);});}];return;}
  dispatch_async(dispatch_get_main_queue(),^{completion(json,status,error);});
 }] resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {completionHandler(nil);}
- (BOOL)hasAccountSession {
 NSURL *origin=[NSURL URLWithString:SXOrigin];for(NSHTTPCookie *cookie in [NSHTTPCookieStorage.sharedHTTPCookieStorage cookiesForURL:origin])if([cookie.name isEqualToString:@"shiye_account.session_token"]&&cookie.secure&&cookie.HTTPOnly&&[cookie.path isEqualToString:@"/"]&&(!cookie.expiresDate||[cookie.expiresDate timeIntervalSinceNow]>0))return YES;return NO;
}
- (void)synchronizeLegacyCookies:(void (^)(void))completion {
 [WKWebsiteDataStore.defaultDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies){
  NSString *host=[NSURL URLWithString:SXOrigin].host;BOOL accountImported=[NSUserDefaults.standardUserDefaults boolForKey:@"native-cookie-import-v1"];
  for(NSHTTPCookie *cookie in cookies){BOOL account=[cookie.name isEqualToString:@"shiye_account.session_token"]||[cookie.name isEqualToString:@"shiye_account.session_data"]||[cookie.name hasPrefix:@"shiye_account.session_data."];BOOL allowed=[cookie.name isEqualToString:@"shiye_ai"]||(!accountImported&&account);if(allowed&&[cookie.domain.lowercaseString isEqualToString:host]&&cookie.secure&&cookie.HTTPOnly&&[cookie.path isEqualToString:@"/"]&&(!cookie.expiresDate||[cookie.expiresDate timeIntervalSinceNow]>0)){NSArray *native=[NSHTTPCookieStorage.sharedHTTPCookieStorage cookiesForURL:[NSURL URLWithString:SXOrigin]];NSHTTPCookie *current=nil;for(NSHTTPCookie *candidate in native)if([candidate.name isEqualToString:cookie.name])current=candidate;if(!current)[NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];}}
  [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"native-cookie-import-v1"];
  dispatch_async(dispatch_get_main_queue(),completion);
 }];
}
@end
