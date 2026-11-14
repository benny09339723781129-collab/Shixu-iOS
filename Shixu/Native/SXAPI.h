#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const SXOrigin;
typedef void (^SXAPICompletion)(id _Nullable json, NSInteger status, NSError * _Nullable error);
@interface SXAPI : NSObject <NSURLSessionTaskDelegate>
+ (instancetype)sharedAPI;
- (void)requestPath:(NSString *)path method:(NSString *)method body:(nullable id)body completion:(SXAPICompletion)completion;
- (void)synchronizeLegacyCookies:(void (^)(void))completion;
- (BOOL)hasAccountSession;
@end
NS_ASSUME_NONNULL_END
