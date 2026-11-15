#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface SXSession : NSObject
+ (instancetype)sharedSession;
- (void)signInFromController:(UIViewController *)controller completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)readLegacyProfileWithCompletion:(void (^)(NSDictionary * _Nullable profile, NSError * _Nullable error))completion;
@end
NS_ASSUME_NONNULL_END
