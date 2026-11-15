#import "SXSession.h"
#import "SXAPI.h"
#import <AuthenticationServices/AuthenticationServices.h>
#import <WebKit/WebKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const SXSessionErrorDomain = @"studio.shixu.session";

static NSError *SXSessionError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:SXSessionErrorDomain code:code
                          userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSString *SXURL64(NSData *data) {
    return [[[[data base64EncodedStringWithOptions:0]
              stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
             stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
            stringByReplacingOccurrencesOfString:@"=" withString:@""];
}

static NSString *SXRandomToken(void) {
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    return SXURL64([NSData dataWithBytes:bytes length:sizeof(bytes)]);
}

static BOOL SXIsToken(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 43) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL SXLegacyURL(NSURL *url) {
    if (!url) return NO;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSURL *origin = [NSURL URLWithString:SXOrigin];
    return [parts.scheme.lowercaseString isEqualToString:@"https"] &&
        [parts.host.lowercaseString isEqualToString:origin.host.lowercaseString] &&
        (!parts.port || parts.port.integerValue == 443) &&
        parts.user == nil && parts.password == nil &&
        [parts.path isEqualToString:@"/privacy.html"] &&
        parts.query == nil && parts.fragment == nil;
}

static NSArray<NSString *> *SXLegacyKeys(void) {
    return @[@"settings",@"watch",@"holdings",@"alerts",@"savedArticles",@"runs",
             @"account.v1",@"account.currency",@"market.cards.US",@"market.cards.TW",
             @"chart.averages",@"nexa.plans",@"nexa.requests",@"intel.bookmarks",@"dark-preference.v3"];
}

static NSArray<NSString *> *SXLegacyListKeys(void) {
    return @[@"watch",@"holdings",@"alerts",@"savedArticles",@"runs",@"chart.averages",
             @"intel.bookmarks",@"market.cards.US",@"market.cards.TW"];
}

static NSArray<NSString *> *SXLegacyObjectKeys(void) {
    return @[@"settings",@"account.v1",@"nexa.plans",@"nexa.requests"];
}

static NSString *SXJSONLiteral(id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSDictionary *SXLegacyProfile(id result) {
    if (![result isKindOfClass:NSString.class]) return nil;
    NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length > 8 * 1024 * 1024) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class] || [decoded count] != 2 ||
        ![decoded[@"version"] isEqual:@1] || ![decoded[@"values"] isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *values = decoded[@"values"];
    if (values.count > 2000) return nil;
    NSSet *keys = [NSSet setWithArray:SXLegacyKeys()];
    NSSet *lists = [NSSet setWithArray:SXLegacyListKeys()];
    NSSet *objects = [NSSet setWithArray:SXLegacyObjectKeys()];
    NSRegularExpression *notes = [NSRegularExpression regularExpressionWithPattern:
                                 @"^note[.][A-Z0-9.\\-]{1,16}$" options:0 error:nil];
    for (id key in values) {
        if (![key isKindOfClass:NSString.class]) return nil;
        BOOL note = [notes numberOfMatchesInString:key options:0 range:NSMakeRange(0, [key length])] == 1;
        if (![keys containsObject:key] && !note) return nil;
        id value = values[key];
        if ((note && ![value isKindOfClass:NSString.class]) ||
            ([lists containsObject:key] && ![value isKindOfClass:NSArray.class]) ||
            ([objects containsObject:key] && ![value isKindOfClass:NSDictionary.class])) return nil;
    }
    return decoded;
}

@interface SXLegacyReader : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
@property(nonatomic) BOOL reading;
@property(nonatomic) BOOL finishing;
@property(nonatomic) BOOL finished;
- (void)startWithCompletion:(void (^)(NSDictionary *, NSError *))completion;
- (void)finishWithProfile:(NSDictionary *)profile error:(NSError *)error;
- (void)completeWithProfile:(NSDictionary *)profile error:(NSError *)error;
@end

@implementation SXLegacyReader

- (void)startWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    self.completion = completion;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    configuration.limitsNavigationsToAppBoundDomains = YES;
    configuration.defaultWebpagePreferences.allowsContentJavaScript = NO;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    self.web = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:configuration];
    self.web.hidden = YES;
    self.web.userInteractionEnabled = NO;
    self.web.accessibilityElementsHidden = YES;
    self.web.navigationDelegate = self;
    // Keep the migration view attached when a scene is available, without showing web UI.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) { [window addSubview:self.web]; break; }
        }
        if (self.web.superview) break;
    }
    NSURL *url = [NSURL URLWithString:[SXOrigin stringByAppendingString:@"/privacy.html"]];
    if (!SXLegacyURL(url)) {
        [self finishWithProfile:nil error:SXSessionError(10,@"舊版資料來源不正確，原資料仍保留。")];
        return;
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                      timeoutInterval:25];
    [self.web loadRequest:request];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SXLegacyReader *reader = weakSelf;
        if (reader && !reader.finished && !reader.finishing)
            [reader finishWithProfile:nil error:SXSessionError(11,@"讀取舊版資料逾時，原資料仍保留，可稍後重試。")];
    });
}

- (void)finishWithProfile:(NSDictionary *)profile error:(NSError *)error {
    if (self.finished || self.finishing) return;
    self.finishing = YES;
    self.web.navigationDelegate = nil;
    [self.web stopLoading];
    [self.web removeFromSuperview];
    self.web = nil;
    __weak typeof(self) weakSelf = self;
    // The API owns the strict cookie whitelist; cookie values never enter the profile.
    [[SXAPI sharedAPI] synchronizeLegacyCookies:^{
        [weakSelf completeWithProfile:profile error:error];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SXLegacyReader *reader = weakSelf;
        if (reader && !reader.finished)
            [reader completeWithProfile:nil error:SXSessionError(12,@"舊版工作階段同步逾時，原資料仍保留，可稍後重試。")];
    });
}

- (void)completeWithProfile:(NSDictionary *)profile error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    void (^completion)(NSDictionary *, NSError *) = self.completion;
    self.completion = nil;
    if (completion) completion(profile,error);
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    BOOL allowed = action.targetFrame.isMainFrame && SXLegacyURL(action.request.URL);
    decisionHandler(allowed ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
    if (!allowed && action.targetFrame.isMainFrame)
        [self finishWithProfile:nil error:SXSessionError(13,@"舊版資料來源已改變，未讀取資料。")];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSHTTPURLResponse *http = [response.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response.response : nil;
    BOOL allowed = response.isForMainFrame && SXLegacyURL(response.response.URL) &&
        http.statusCode == 200 && [response.response.MIMEType.lowercaseString isEqualToString:@"text/html"];
    decisionHandler(allowed ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyCancel);
    if (!allowed)
        [self finishWithProfile:nil error:SXSessionError(14,@"舊版資料頁暫時無法讀取，原資料仍保留。")];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.reading || self.finishing || self.finished) return;
    if (webView != self.web || !SXLegacyURL(webView.URL)) {
        [self finishWithProfile:nil error:SXSessionError(15,@"舊版資料來源驗證失敗，未讀取資料。")];
        return;
    }
    self.reading = YES;
    NSString *script = [NSString stringWithFormat:
        @"(()=>{'use strict';const allowed=new Set(%@),lists=new Set(%@),objects=new Set(%@);"
         @"const values=Object.create(null);let count=0;"
         @"for(let i=0;i<localStorage.length;i++){const full=localStorage.key(i);"
         @"if(!full||!full.startsWith('shiye.studio.'))continue;const key=full.slice(13);"
         @"const note=/^note[.][A-Z0-9.\\-]{1,16}$/.test(key);if(!allowed.has(key)&&!note)continue;"
         @"if(++count>2000)throw Error('invalid-profile');const raw=localStorage.getItem(full);"
         @"if(typeof raw!=='string')throw Error('invalid-profile');const value=JSON.parse(raw);"
         @"if((note&&typeof value!=='string')||(lists.has(key)&&!Array.isArray(value))||"
         @"(objects.has(key)&&(!value||typeof value!=='object'||Array.isArray(value))))throw Error('invalid-profile');"
         @"values[key]=value;}const profile=JSON.stringify({version:1,values});"
         @"if(new TextEncoder().encode(profile).length>8388608)throw Error('invalid-profile');return profile;})()",
        SXJSONLiteral(SXLegacyKeys()),SXJSONLiteral(SXLegacyListKeys()),SXJSONLiteral(SXLegacyObjectKeys())];
    __weak typeof(self) weakSelf = self;
    [webView evaluateJavaScript:script inFrame:nil
                inContentWorld:[WKContentWorld worldWithName:@"ShixuLegacyMigration"]
             completionHandler:^(id result, NSError *error) {
        SXLegacyReader *reader = weakSelf;
        if (!reader || reader.finished || reader.finishing) return;
        if (error || !SXLegacyURL(reader.web.URL)) {
            [reader finishWithProfile:nil error:SXSessionError(16,@"無法讀取舊版資料，原資料仍保留，可稍後重試。")];
            return;
        }
        NSDictionary *profile = SXLegacyProfile(result);
        [reader finishWithProfile:profile error:profile ? nil : SXSessionError(17,@"舊版資料格式不完整，未匯入或清除任何資料。")];
    }];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithProfile:nil error:SXSessionError(18,@"舊版資料連線未完成，原資料仍保留，可稍後重試。")];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithProfile:nil error:SXSessionError(18,@"舊版資料連線未完成，原資料仍保留，可稍後重試。")];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    [self finishWithProfile:nil error:SXSessionError(19,@"舊版資料讀取已中斷，原資料仍保留，可稍後重試。")];
}
@end

@interface SXSession () <ASWebAuthenticationPresentationContextProviding>
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, weak) UIWindow *presentationWindow;
@property(nonatomic, strong) ASWebAuthenticationSession *authentication;
@property(nonatomic, copy) NSString *verifier;
@property(nonatomic, copy) NSString *authState;
@property(nonatomic, strong) NSUUID *authIdentifier;
@property(nonatomic, copy) void (^authCompletion)(BOOL, NSError *);
@property(nonatomic) BOOL exchanging;
@property(nonatomic, strong) SXLegacyReader *legacyReader;
- (void)exchangeCallback:(NSURL *)callback identifier:(NSUUID *)identifier;
- (void)finishAuthentication:(BOOL)success error:(NSError *)error;
@end

@implementation SXSession

+ (instancetype)sharedSession {
    static SXSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ session = [SXSession new]; });
    return session;
}

- (void)signInFromController:(UIViewController *)controller completion:(void (^)(BOOL, NSError *))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self signInFromController:controller completion:completion]; });
        return;
    }
    if (self.authIdentifier || self.legacyReader) {
        if (completion) completion(NO,SXSessionError(1,@"另一項登入或資料讀取正在進行，請稍後再試。"));
        return;
    }
    UIWindow *window = controller.viewIfLoaded.window;
    if (!controller || !window) {
        if (completion) completion(NO,SXSessionError(2,@"請回到 App 畫面後再登入。"));
        return;
    }
    NSString *verifier = SXRandomToken(), *state = SXRandomToken();
    if (!verifier || !state) {
        if (completion) completion(NO,SXSessionError(3,@"無法建立登入驗證，請稍後再試。"));
        return;
    }
    self.presenter = controller;
    self.presentationWindow = window;
    self.verifier = verifier;
    self.authState = state;
    self.authCompletion = completion;
    self.exchanging = NO;
    NSUUID *identifier = NSUUID.UUID;
    self.authIdentifier = identifier;
    NSData *bytes = [verifier dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,hash);
    NSURLComponents *start = [NSURLComponents componentsWithString:[SXOrigin stringByAppendingString:@"/api/account/native-login"]];
    start.queryItems = @[[NSURLQueryItem queryItemWithName:@"challenge" value:SXURL64([NSData dataWithBytes:hash length:sizeof(hash)])],
                         [NSURLQueryItem queryItemWithName:@"state" value:state]];
    __weak typeof(self) weakSelf = self;
    self.authentication = [[ASWebAuthenticationSession alloc] initWithURL:start.URL callbackURLScheme:@"shixu"
                                                     completionHandler:^(NSURL *callback, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SXSession *session = weakSelf;
            if (!session || ![session.authIdentifier isEqual:identifier] || session.exchanging) return;
            if (error || !callback) {
                BOOL cancelled = [error.domain isEqualToString:ASWebAuthenticationSessionErrorDomain] &&
                    error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin;
                [session finishAuthentication:NO error:SXSessionError(cancelled ? NSUserCancelledError : 4,
                    cancelled ? @"已取消登入，原本的資料仍保留。" : @"登入未完成，請重新嘗試。")];
                return;
            }
            [session exchangeCallback:callback identifier:identifier];
        });
    }];
    self.authentication.presentationContextProvider = self;
    self.authentication.prefersEphemeralWebBrowserSession = NO;
    if (![self.authentication start]) {
        [self finishAuthentication:NO error:SXSessionError(5,@"無法開啟 Google 登入，請稍後再試。")];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SXSession *session = weakSelf;
        // Once exchange starts, the API's network timeout owns completion. Do not
        // permit a second sign-in while a previous exchange could still set cookies.
        if ([session.authIdentifier isEqual:identifier] && !session.exchanging)
            [session finishAuthentication:NO error:SXSessionError(6,@"登入已逾時，請重新登入。")];
    });
}

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return self.presentationWindow ?: self.presenter.viewIfLoaded.window;
}

- (void)exchangeCallback:(NSURL *)callback identifier:(NSUUID *)identifier {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO];
    NSMutableDictionary<NSString *,NSString *> *parameters = [NSMutableDictionary new];
    BOOL duplicate = NO;
    for (NSURLQueryItem *item in parts.queryItems) {
        if (parameters[item.name] != nil) duplicate = YES;
        parameters[item.name] = item.value ?: @"";
    }
    BOOL valid = !duplicate && parameters.count == 2 &&
        [parts.scheme isEqualToString:@"shixu"] && [parts.host isEqualToString:@"auth"] &&
        parts.user == nil && parts.password == nil && parts.port == nil && parts.fragment == nil && parts.path.length == 0 &&
        SXIsToken(parameters[@"code"]) && SXIsToken(parameters[@"state"]) &&
        [parameters[@"state"] isEqualToString:self.authState] && SXIsToken(self.verifier);
    if (!valid) {
        [self finishAuthentication:NO error:SXSessionError(7,@"登入回傳驗證失敗，請重新登入。")];
        return;
    }
    self.exchanging = YES;
    NSDictionary *body = @{@"code":parameters[@"code"],@"state":self.authState,@"verifier":self.verifier};
    __weak typeof(self) weakSelf = self;
    [[SXAPI sharedAPI] requestPath:@"/api/account/native-exchange" method:@"POST" body:body
                       completion:^(id json, NSInteger status, NSError *error) {
        SXSession *session = weakSelf;
        if (!session || ![session.authIdentifier isEqual:identifier]) return;
        NSDictionary *response = [json isKindOfClass:NSDictionary.class] ? json : nil;
        BOOL signedIn = [response[@"signedIn"] isKindOfClass:NSNumber.class] && [response[@"signedIn"] boolValue];
        BOOL success = !error && status == 200 && signedIn && [[SXAPI sharedAPI] hasAccountSession];
        [session finishAuthentication:success error:success ? nil : SXSessionError(8,@"App 登入未完成，請重新登入，原本的資料仍保留。")];
    }];
}

- (void)finishAuthentication:(BOOL)success error:(NSError *)error {
    if (!self.authIdentifier) return;
    void (^completion)(BOOL, NSError *) = self.authCompletion;
    ASWebAuthenticationSession *authentication = self.authentication;
    self.authIdentifier = nil;
    self.authCompletion = nil;
    self.authentication = nil;
    self.presenter = nil;
    self.presentationWindow = nil;
    self.verifier = nil;
    self.authState = nil;
    self.exchanging = NO;
    if (!success) [authentication cancel];
    if (completion) completion(success,error);
}

- (void)readLegacyProfileWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self readLegacyProfileWithCompletion:completion]; });
        return;
    }
    if (self.authIdentifier || self.legacyReader) {
        if (completion) completion(nil,SXSessionError(1,@"另一項登入或資料讀取正在進行，請稍後再試。"));
        return;
    }
    SXLegacyReader *reader = [SXLegacyReader new];
    self.legacyReader = reader;
    __weak typeof(self) weakSelf = self;
    [reader startWithCompletion:^(NSDictionary *profile, NSError *error) {
        SXSession *session = weakSelf;
        if (!session || session.legacyReader != reader) return;
        session.legacyReader = nil;
        if (completion) completion(profile,error);
    }];
}
@end
