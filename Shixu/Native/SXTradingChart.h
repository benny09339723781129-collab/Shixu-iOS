#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface SXTradingChart : UIView <WKNavigationDelegate>
@property(nonatomic,copy) NSArray<NSDictionary *> *rows;
@property(nonatomic,copy) NSArray<NSDictionary *> *forecast;
@property(nonatomic,copy) NSArray<NSNumber *> *averages;
@property(nonatomic,copy) NSString *period;
@property(nonatomic) NSInteger visibleBars;
@property(nonatomic,strong,nullable) NSNumber *latestClose;
@property(nonatomic,copy,nullable) void (^readoutChanged)(NSString *text);
@property(nonatomic,readonly) WKWebView *webView;
- (void)render;
- (void)useLocalChart;
- (void)reset;
- (void)showIntradayForSymbol:(NSString *)symbol;
@end
NS_ASSUME_NONNULL_END
