#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSNotificationName const SXStoreDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const SXQuotesDidChangeNotification;
@interface SXStore : NSObject
+ (instancetype)sharedStore;
@property(nonatomic,readonly) NSDictionary<NSString *,id> *profile;
@property(nonatomic,readonly) NSDictionary *account;
@property(nonatomic,readonly) NSArray<NSDictionary *> *runs;
@property(nonatomic,readonly) NSArray<NSString *> *watchCodes;
@property(nonatomic,readonly) NSDictionary<NSString *,NSDictionary *> *quotes;
@property(nonatomic,readonly) NSSet<NSString *> *quoteErrors;
@property(nonatomic,readonly) NSArray<NSDictionary *> *directory;
@property(nonatomic,readonly,nullable) NSString *persistenceError;
@property(nonatomic,readonly,copy,nullable) NSString *activeProfileUserID;
@property(nonatomic) BOOL accountIdentityResolved;
- (BOOL)activateProfileForUserID:(nullable NSString *)userID error:(NSError **)error;
- (BOOL)copyLocalProfileToActiveAccount:(NSError **)error;
- (id)valueForProfileKey:(NSString *)key fallback:(id)fallback;
- (BOOL)setProfileValue:(id)value forKey:(NSString *)key;
- (id)setting:(NSString *)key fallback:(id)fallback;
- (BOOL)setSetting:(id)value forKey:(NSString *)key;
- (BOOL)saveAccount:(NSDictionary *)account;
- (BOOL)upsertRun:(NSDictionary *)run;
- (BOOL)isPinned:(NSString *)runID;
- (void)togglePin:(NSString *)runID;
- (void)setWatchCodes:(NSArray<NSString *> *)codes;
- (nullable NSDictionary *)stockForCode:(NSString *)code;
- (NSString *)sourceSymbolForCode:(NSString *)code;
- (void)refreshQuotesForCodes:(NSArray<NSString *> *)codes completion:(nullable void (^)(void))completion;
- (nullable NSData *)exportProfileData:(NSError **)error;
- (BOOL)importProfile:(NSDictionary *)profile replace:(BOOL)replace error:(NSError **)error;
- (BOOL)hasPersonalData;
- (NSArray<NSURL *> *)restoreCopiesForActiveProfile;
@end
NS_ASSUME_NONNULL_END
