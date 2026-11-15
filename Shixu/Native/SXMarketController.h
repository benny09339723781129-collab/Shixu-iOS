#import <UIKit/UIKit.h>
@interface SXMarketController : UITableViewController
- (void)openAssets:(UIButton *)sender;
@end
@interface SXNewsController : UITableViewController
@end
@interface SXStockController : UITableViewController
- (instancetype)initWithCode:(NSString *)code;
@end
