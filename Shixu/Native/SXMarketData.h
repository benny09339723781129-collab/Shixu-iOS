#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef void (^SXMarketReply)(NSDictionary * _Nullable value, NSError * _Nullable error);
@interface SXMarketData : NSObject <NSURLSessionTaskDelegate>
+ (instancetype)shared;
- (void)quoteForCode:(NSString *)code completion:(SXMarketReply)completion;
- (void)historyForCode:(NSString *)code completion:(SXMarketReply)completion;
+ (NSArray<NSDictionary *> *)nasdaqRows:(id)payload symbol:(NSString *)symbol;
+ (NSArray<NSDictionary *> *)taiwanRows:(id)payload code:(NSString *)code otc:(BOOL)otc;
@end
NS_ASSUME_NONNULL_END
