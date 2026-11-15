#import "SXTradingChart.h"
#import "SXStore.h"
#import "SXUI.h"
#import <SafariServices/SafariServices.h>

@class SXChartMessage;
@interface SXTradingChart ()
@property(nonatomic,strong) WKWebView *webView;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL remote;
@property(nonatomic,copy) NSString *remoteSymbol;
@property(nonatomic,strong) UILabel *fixtureNotice;
- (void)receive:(NSDictionary *)message;
@end
@interface SXChartMessage : NSObject <WKScriptMessageHandler>
@property(nonatomic,weak) SXTradingChart *chart;
@end
@implementation SXChartMessage
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message { if(message.frameInfo.isMainFrame&&message.webView.URL.isFileURL&&[message.body isKindOfClass:NSDictionary.class])[self.chart receive:message.body]; }
@end
@implementation SXTradingChart
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.rows=@[];self.forecast=@[];self.averages=@[@5,@20];self.period=@"day";self.visibleBars=66;
        self.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;self.layer.cornerRadius=14;self.clipsToBounds=YES;
        WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];configuration.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
        SXChartMessage *message=[SXChartMessage new];message.chart=self;[configuration.userContentController addScriptMessageHandler:message name:@"chartEvent"];
        self.webView=[[WKWebView alloc] initWithFrame:self.bounds configuration:configuration];self.webView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        self.webView.navigationDelegate=self;self.webView.opaque=NO;self.webView.backgroundColor=UIColor.clearColor;self.webView.scrollView.scrollEnabled=NO;self.webView.scrollView.bounces=NO;self.webView.allowsLinkPreview=NO;
        self.accessibilityIdentifier=@"chart.plot";self.isAccessibilityElement=YES;self.accessibilityLabel=@"TradingView K 線圖";self.webView.accessibilityIdentifier=@"chart.web";[self addSubview:self.webView];[self loadLocal];
    } return self;
}
- (void)dealloc { [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"chartEvent"];self.webView.navigationDelegate=nil;[self.webView stopLoading]; }
- (void)loadLocal {
    self.ready=NO;self.remote=NO;
    NSURL *file=[NSBundle.mainBundle URLForResource:@"index" withExtension:@"html" subdirectory:@"Chart"];
    if(file)[self.webView loadFileURL:file allowingReadAccessToURL:[file URLByDeletingLastPathComponent]];
}
- (void)traitCollectionDidChange:(UITraitCollection *)previous { [super traitCollectionDidChange:previous];if(self.remote){if(previous.userInterfaceStyle!=self.traitCollection.userInterfaceStyle)[self showIntradayForSymbol:self.remoteSymbol];}else [self render]; }
- (void)useLocalChart {self.webView.hidden=NO;[self.fixtureNotice removeFromSuperview];self.fixtureNotice=nil;self.isAccessibilityElement=YES;if(self.remote)[self loadLocal];else[self render];}
- (void)render {
    if(self.remote || !self.ready)return;
    BOOL upRed=[[SXStore.sharedStore setting:@"up" fallback:@"green"] isEqual:@"red"];
    NSDictionary *payload=@{@"rows":self.rows?:@[],@"forecast":self.forecast?:@[],@"latestClose":self.latestClose?:NSNull.null,@"averages":self.averages?:@[],@"period":self.period?:@"day",@"visible":@(self.visibleBars),@"dark":@(self.traitCollection.userInterfaceStyle==UIUserInterfaceStyleDark),@"upRed":@(upRed)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];if(!data)return;
    NSString *script=[NSString stringWithFormat:@"window.SXChart.render(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('%@'),c=>c.charCodeAt(0)))))",[data base64EncodedStringWithOptions:0]];
    [self.webView evaluateJavaScript:script completionHandler:^(id result,NSError *error){if(error && self.readoutChanged)self.readoutChanged(@"圖表載入未完成，請重設後重試。");}];
}
- (void)reset {if(!self.remote)[self.webView evaluateJavaScript:@"window.SXChart.reset()" completionHandler:nil];}
- (void)receive:(NSDictionary *)message {
    if(self.remote)return;
    if([message[@"type"] isEqual:@"ready"]){self.ready=YES;[self render];}
    if([message[@"type"] isEqual:@"readout"] && [message[@"text"] isKindOfClass:NSString.class] && self.readoutChanged)self.readoutChanged(message[@"text"]);
    if([message[@"type"] isEqual:@"state"]){self.accessibilityValue=[NSString stringWithFormat:@"%@ 根%@，可左右拖曳、雙指縮放或長按查看。",message[@"bars"]?:@0,[message[@"period"] isEqual:@"week"]?@"週 K":@"日 K"];
#if DEBUG
        if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]){NSMutableDictionary *state=[message mutableCopy];[state removeObjectForKey:@"type"];NSData *data=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];self.accessibilityValue=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:@"";}
#endif
    }
}
- (void)showIntradayForSymbol:(NSString *)symbol {
    self.remoteSymbol=symbol;
#if DEBUG
    if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]){self.remote=YES;self.webView.hidden=YES;[self.fixtureNotice removeFromSuperview];self.fixtureNotice=[UILabel new];self.fixtureNotice.text=@"15 分行情由 TradingView 提供\n隔離測試不連線，也不以日 K 冒充。";self.fixtureNotice.numberOfLines=0;self.fixtureNotice.textAlignment=NSTextAlignmentCenter;self.fixtureNotice.textColor=UIColor.secondaryLabelColor;self.fixtureNotice.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.fixtureNotice.frame=CGRectInset(self.bounds,20,20);self.fixtureNotice.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self addSubview:self.fixtureNotice];self.accessibilityValue=@"{\"bars\":0,\"period\":\"intraday\",\"visibleFrom\":0,\"visibleTo\":0,\"ma\":[]}";if(self.readoutChanged)self.readoutChanged(@"隔離測試不下載盤中行情；日 K 與週 K 可操作。");return;}
#endif
    self.remote=YES;self.ready=NO;self.isAccessibilityElement=NO;
    NSDictionary *options=@{@"autosize":@YES,@"symbol":symbol,@"interval":@"15",@"timezone":@"Asia/Taipei",@"theme":self.traitCollection.userInterfaceStyle==UIUserInterfaceStyleDark?@"dark":@"light",@"style":@"1",@"locale":@"zh_TW",@"allow_symbol_change":@NO,@"hide_side_toolbar":@NO,@"withdateranges":@YES,@"support_host":@"https://www.tradingview.com"};
    NSString *json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:options options:0 error:nil] encoding:NSUTF8StringEncoding];
    NSString *html=[NSString stringWithFormat:@"<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='Content-Security-Policy' content=\"default-src https://*.tradingview.com; script-src https://*.tradingview.com 'unsafe-inline'; style-src 'unsafe-inline' https://*.tradingview.com; frame-src https://*.tradingview.com https://www.tradingview-widget.com; img-src data: https://*.tradingview.com\"><style>html,body,.tradingview-widget-container,.tradingview-widget-container__widget{margin:0;width:100%%;height:100%%}</style></head><body><div class='tradingview-widget-container'><div class='tradingview-widget-container__widget'></div><script src='https://s3.tradingview.com/external-embedding/embed-widget-advanced-chart.js' async>%@</script></div></body></html>",json];
    [self.webView loadHTMLString:html baseURL:[NSURL URLWithString:@"https://www.tradingview.com/"]];
    if(self.readoutChanged)self.readoutChanged(@"TradingView · 15 分 K；由圖表來源標示市場與延遲。");
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
    NSURL *url=action.request.URL;NSString *host=url.host.lowercaseString;
    BOOL trading=[host isEqual:@"tradingview.com"]||[host hasSuffix:@".tradingview.com"]||[host isEqual:@"www.tradingview-widget.com"];
    if(url.isFileURL || [url.scheme isEqual:@"about"] || (self.remote&&trading&&[url.scheme isEqual:@"https"])){decision(WKNavigationActionPolicyAllow);return;}
    decision(WKNavigationActionPolicyCancel);
    if(action.navigationType==WKNavigationTypeLinkActivated&&trading&&[url.scheme isEqual:@"https"])[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {if(error.code!=NSURLErrorCancelled&&self.readoutChanged)self.readoutChanged(@"圖表來源暫時無法連線，可切回日 K 或稍後重試。");}
@end
