#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <SafariServices/SafariServices.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const Origin = @"https://trend-forecast.pc-remote-worker.workers.dev";
static BOOL FirstParty(NSURL *url) {
    NSURL *base = [NSURL URLWithString:Origin];
    return [url.scheme.lowercaseString isEqualToString:@"https"] &&
      [url.host.lowercaseString isEqualToString:base.host] && (!url.port || url.port.integerValue == 443) &&
      !url.user && !url.password;
}
static NSString *Base64URL(NSData *data) {
    return [[[[data base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
      stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSString *RandomToken(void) {
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    return Base64URL([NSData dataWithBytes:bytes length:sizeof(bytes)]);
}
static BOOL IsToken(NSString *text) {
    return [text isKindOfClass:NSString.class] && text.length == 43 &&
      [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet]].location == NSNotFound;
}

@class ShixuController;
@interface ShixuBridge : NSObject <WKScriptMessageHandler>
@property(nonatomic, weak) ShixuController *owner;
@end

@interface ShixuController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, ASWebAuthenticationPresentationContextProviding, NSURLSessionTaskDelegate>
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, strong) UIView *loading;
@property(nonatomic, strong) UILabel *loadingText;
@property(nonatomic, strong) UIButton *retry;
@property(nonatomic, strong) ASWebAuthenticationSession *auth;
@property(nonatomic, copy) NSString *verifier;
@property(nonatomic, copy) NSString *authState;
@property(nonatomic, strong) NSURL *downloadURL;
@property(nonatomic, strong) WKDownload *activeDownload;
@property(nonatomic) NSTimeInterval started;
@property(nonatomic) BOOL dark;
- (void)receive:(WKScriptMessage *)message;
@end

@implementation ShixuBridge
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.owner receive:message];
}
@end

@implementation ShixuController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.dark = YES;
    self.started = NSProcessInfo.processInfo.systemUptime;
    self.view.backgroundColor = [UIColor colorWithRed:18/255.0 green:27/255.0 blue:24/255.0 alpha:1];
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    config.applicationNameForUserAgent = @"ShixuNative/1.0";
    config.limitsNavigationsToAppBoundDomains = YES;
    ShixuBridge *bridge = [ShixuBridge new]; bridge.owner = self;
    [config.userContentController addScriptMessageHandler:bridge name:@"shixu"];
    NSString *source = @"Object.defineProperty(window,'ShixuNative',{value:Object.freeze({version:1,login:function(){window.webkit.messageHandlers.shixu.postMessage({action:'login'});}})});";
    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:source injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    NSString *theme = @"(()=>{const send=()=>{const m=getComputedStyle(document.body).backgroundColor.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)/);if(m)window.webkit.messageHandlers.shixu.postMessage({action:'theme',rgb:m.slice(1).map(Number)});};send();new MutationObserver(send).observe(document.documentElement,{attributes:true,attributeFilter:['data-theme','class','style']});})();";
    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:theme injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.web.navigationDelegate = self; self.web.UIDelegate = self;
    self.web.allowsBackForwardNavigationGestures = YES;
    self.web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.web.opaque = NO; self.web.backgroundColor = self.view.backgroundColor;
    self.web.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:self.web];
    [NSLayoutConstraint activateConstraints:@[[self.web.topAnchor constraintEqualToAnchor:self.view.topAnchor],[self.web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    self.loading = [[UIView alloc] initWithFrame:self.view.bounds];
    self.loading.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.loading.backgroundColor = self.view.backgroundColor;
    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"ShixuLogo.png"]];
    logo.contentMode = UIViewContentModeScaleAspectFit;
    self.loadingText = [UILabel new]; self.loadingText.text = @"拾序"; self.loadingText.textColor = UIColor.whiteColor;
    self.loadingText.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold]; self.loadingText.textAlignment = NSTextAlignmentCenter;
    self.retry = [UIButton buttonWithType:UIButtonTypeSystem]; [self.retry setTitle:@"重新連線" forState:UIControlStateNormal];
    self.retry.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]; self.retry.hidden = YES;
    [self.retry addTarget:self action:@selector(loadApp) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logo,self.loadingText,self.retry]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 18; stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO; [self.loading addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[logo.widthAnchor constraintEqualToConstant:72],[logo.heightAnchor constraintEqualToConstant:72],[stack.centerXAnchor constraintEqualToAnchor:self.loading.centerXAnchor],[stack.centerYAnchor constraintEqualToAnchor:self.loading.centerYAnchor]]];
    [self.view addSubview:self.loading]; [self loadApp];
}
- (UIStatusBarStyle)preferredStatusBarStyle { return self.dark ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent; }
- (void)loadApp {
    self.retry.hidden = YES; self.loadingText.text = @"拾序"; self.loading.hidden = NO; self.loading.alpha = 1;
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"last-page"];
    NSURL *url = saved ? [NSURL URLWithString:saved] : nil;
    if (!FirstParty(url) || ![url.path isEqualToString:@"/"]) url = [NSURL URLWithString:[Origin stringByAppendingString:@"/#market"]];
    [self.web loadRequest:[NSURLRequest requestWithURL:url]];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (FirstParty(webView.URL) && [webView.URL.path isEqualToString:@"/"]) [NSUserDefaults.standardUserDefaults setObject:webView.URL.absoluteString forKey:@"last-page"];
    NSTimeInterval delay = MAX(0, 1.2 - (NSProcessInfo.processInfo.systemUptime - self.started));
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{ weakSelf.loading.alpha = 0; } completion:^(BOOL done){ weakSelf.loading.hidden = YES; }];
    });
}
- (void)loadFailed:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    self.loading.hidden = NO; self.loading.alpha = 1; self.loadingText.text = @"目前無法連線"; self.retry.hidden = NO;
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self loadFailed:error]; }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self loadFailed:error]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { [self loadFailed:[NSError errorWithDomain:@"Shixu" code:1 userInfo:nil]]; }
- (void)external:(NSURL *)url {
    if (![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]) return;
    SFSafariViewController *browser = [[SFSafariViewController alloc] initWithURL:url];
    [self presentViewController:browser animated:YES completion:nil];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    BOOL blob = [url.absoluteString hasPrefix:[@"blob:" stringByAppendingFormat:@"%@/", Origin]];
    if ((FirstParty(url) || blob) && action.shouldPerformDownload) { decisionHandler(WKNavigationActionPolicyDownload); return; }
    if (FirstParty(url) || blob) { decisionHandler(WKNavigationActionPolicyAllow); return; }
    decisionHandler(WKNavigationActionPolicyCancel);
    if (action.navigationType == WKNavigationTypeLinkActivated) [self external:url];
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (FirstParty(action.request.URL)) [self.web loadRequest:action.request]; else [self external:action.request.URL];
    return nil;
}
- (void)receive:(WKScriptMessage *)message {
    WKSecurityOrigin *origin = message.frameInfo.securityOrigin;
    if (!message.frameInfo.mainFrame || ![origin.protocol isEqualToString:@"https"] || ![origin.host isEqualToString:[NSURL URLWithString:Origin].host] || (origin.port != 0 && origin.port != 443) || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = message.body;
    if ([body[@"action"] isEqual:@"login"]) [self signIn];
    if ([body[@"action"] isEqual:@"theme"] && [body[@"rgb"] isKindOfClass:NSArray.class] && [body[@"rgb"] count] == 3) {
        NSArray *rgb = body[@"rgb"];
        for (id value in rgb) if (![value isKindOfClass:NSNumber.class] || [value doubleValue] < 0 || [value doubleValue] > 255) return;
        self.dark = [rgb[0] doubleValue]*0.299 + [rgb[1] doubleValue]*0.587 + [rgb[2] doubleValue]*0.114 < 128;
        self.view.backgroundColor = [UIColor colorWithRed:[rgb[0] doubleValue]/255 green:[rgb[1] doubleValue]/255 blue:[rgb[2] doubleValue]/255 alpha:1];
        self.web.backgroundColor = self.view.backgroundColor; [self setNeedsStatusBarAppearanceUpdate];
    }
}
- (void)authFinished:(BOOL)success cancelled:(BOOL)cancelled {
    self.auth = nil; self.verifier = nil; self.authState = nil;
    NSString *event = success ? @"shixu-native-login-complete" : @"shixu-native-login-cancelled";
    [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.dispatchEvent(new Event('%@'))",event] completionHandler:nil];
    if (!success && !cancelled) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"登入未完成" message:@"請重新登入，原本的資料仍保留。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session { return self.view.window; }
- (void)signIn {
    if (self.auth) return;
    self.verifier = RandomToken(); self.authState = RandomToken();
    if (!self.verifier || !self.authState) { [self authFinished:NO cancelled:NO]; return; }
    NSData *bytes = [self.verifier dataUsingEncoding:NSUTF8StringEncoding]; uint8_t hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
    NSURLComponents *start = [NSURLComponents componentsWithString:[Origin stringByAppendingString:@"/api/account/native-login"]];
    start.queryItems = @[[NSURLQueryItem queryItemWithName:@"challenge" value:Base64URL([NSData dataWithBytes:hash length:sizeof(hash)])],[NSURLQueryItem queryItemWithName:@"state" value:self.authState]];
    __weak typeof(self) weakSelf = self;
    self.auth = [[ASWebAuthenticationSession alloc] initWithURL:start.URL callbackURLScheme:@"shixu" completionHandler:^(NSURL *callback, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ShixuController *owner = weakSelf; if (!owner) return;
            if (error || !callback) { [owner authFinished:NO cancelled:error.code == ASWebAuthenticationSessionErrorCodeCanceledLogin]; return; }
            [owner exchange:callback];
        });
    }];
    self.auth.presentationContextProvider = self; self.auth.prefersEphemeralWebBrowserSession = NO;
    if (![self.auth start]) [self authFinished:NO cancelled:NO];
}
- (void)exchange:(NSURL *)callback {
    NSURLComponents *parts = [NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO];
    NSMutableDictionary *parameters = [NSMutableDictionary new]; BOOL duplicate = NO;
    for (NSURLQueryItem *item in parts.queryItems) { if (parameters[item.name]) duplicate = YES; parameters[item.name] = item.value ?: @""; }
    if (duplicate || parameters.count != 2 || ![parts.scheme isEqualToString:@"shixu"] || ![parts.host isEqualToString:@"auth"] || parts.user || parts.password || parts.port || parts.fragment || parts.path.length || ![parameters[@"state"] isEqual:self.authState] || !IsToken(parameters[@"code"]) || !self.verifier) { [self authFinished:NO cancelled:NO]; return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[Origin stringByAppendingString:@"/api/account/native-exchange"]]];
    request.HTTPMethod = @"POST"; request.timeoutInterval = 25; request.HTTPShouldHandleCookies = NO;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"code":parameters[@"code"],@"state":self.authState,@"verifier":self.verifier} options:0 error:nil];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPShouldSetCookies = NO; config.HTTPCookieStorage = nil;
    config.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    __weak typeof(self) weakSelf = self;
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        NSArray<NSHTTPCookie *> *cookies = http ? [NSHTTPCookie cookiesWithResponseHeaderFields:http.allHeaderFields forURL:request.URL] : @[];
        NSMutableArray *accepted = [NSMutableArray new];
        for (NSHTTPCookie *cookie in cookies) if ([cookie.name isEqualToString:@"shiye_account.session_token"] && cookie.secure && cookie.HTTPOnly && [cookie.domain.lowercaseString isEqualToString:request.URL.host] && [cookie.path isEqualToString:@"/"]) [accepted addObject:cookie];
        dispatch_async(dispatch_get_main_queue(), ^{
            ShixuController *owner = weakSelf; if (!owner) return;
            if (error || http.statusCode != 200 || accepted.count != 1) { [owner authFinished:NO cancelled:NO]; return; }
            WKHTTPCookieStore *store = owner.web.configuration.websiteDataStore.httpCookieStore;
            [store getAllCookies:^(NSArray<NSHTTPCookie *> *stored) {
                dispatch_group_t group = dispatch_group_create();
                for (NSHTTPCookie *cookie in stored) if ([cookie.domain.lowercaseString isEqualToString:request.URL.host] && ([cookie.name isEqualToString:@"shiye_account.session_data"] || [cookie.name hasPrefix:@"shiye_account.session_data."])) {
                    dispatch_group_enter(group); [store deleteCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
                }
                dispatch_group_notify(group, dispatch_get_main_queue(), ^{ [store setCookie:accepted.firstObject completionHandler:^{ [owner authFinished:YES cancelled:NO]; }]; });
            }];
        });
        [session finishTasksAndInvalidate];
    }] resume];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)action didBecomeDownload:(WKDownload *)download { download.delegate = self; }
- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)response didBecomeDownload:(WKDownload *)download { download.delegate = self; }
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    decisionHandler(!response.canShowMIMEType && FirstParty(response.response.URL) ? WKNavigationResponsePolicyDownload : WKNavigationResponsePolicyAllow);
}
- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)name completionHandler:(void (^)(NSURL *))completionHandler {
    if (self.activeDownload) { completionHandler(nil); return; }
    self.activeDownload = download;
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [base URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *error = nil; [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
    NSString *filename = name.lastPathComponent.length && ![@[@".",@".."] containsObject:name.lastPathComponent] ? name.lastPathComponent : @"拾序匯出.json";
    self.downloadURL = [directory URLByAppendingPathComponent:filename]; completionHandler(error ? nil : self.downloadURL);
}
- (void)downloadDidFinish:(WKDownload *)download {
    if (download != self.activeDownload || !self.downloadURL) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[self.downloadURL] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view; share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMidY(self.view.bounds),1,1);
    [self presentViewController:share animated:YES completion:nil]; self.downloadURL = nil; self.activeDownload = nil;
}
- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData { if (download == self.activeDownload) { self.downloadURL = nil; self.activeDownload = nil; } }
@end

@interface ShixuSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation ShixuSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ShixuController new]; [self.window makeKeyAndVisible];
}
@end
@interface ShixuAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ShixuAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:session.role];
    config.delegateClass = ShixuSceneDelegate.class; return config;
}
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ShixuAppDelegate.class)); } }
