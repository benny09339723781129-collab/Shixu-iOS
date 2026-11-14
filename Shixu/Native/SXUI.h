#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT UIButton *SXGlassButton(NSString *title, NSString * _Nullable symbol, UIAction *action);
FOUNDATION_EXPORT NSString *SXMoney(id _Nullable value, NSString *currency);
FOUNDATION_EXPORT NSString *SXFormatNumber(id _Nullable value, NSInteger decimals);
FOUNDATION_EXPORT BOOL SXFiniteNumber(id _Nullable value);
FOUNDATION_EXPORT NSString *SXDateLabel(id _Nullable value);
FOUNDATION_EXPORT NSString *SXQuoteLabel(NSDictionary * _Nullable quote, BOOL stale);
FOUNDATION_EXPORT void SXShowError(UIViewController *controller, NSString *title, NSString *message);
FOUNDATION_EXPORT void SXShare(UIViewController *controller, id item);
NS_ASSUME_NONNULL_END
