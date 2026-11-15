#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface SXResearchController : UITableViewController
- (void)openSetupForCode:(NSString *)code;
- (void)openSetupForCode:(NSString *)code fromNavigation:(UINavigationController *)navigation;
- (void)openRun:(NSDictionary *)run;
@end
NS_ASSUME_NONNULL_END
