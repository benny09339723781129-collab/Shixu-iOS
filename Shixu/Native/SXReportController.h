#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface SXReportController : UITableViewController
- (instancetype)initWithRun:(NSDictionary *)run;
- (void)displayArchivedRun:(NSDictionary *)run;
+ (BOOL)archiveNexaRun:(NSDictionary *)run forCode:(NSString *)code requestID:(NSString *)requestID;
+ (BOOL)finishNexaRequestForCode:(NSString *)code requestID:(NSString *)requestID;
@end
NS_ASSUME_NONNULL_END
