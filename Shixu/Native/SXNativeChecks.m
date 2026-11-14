#import "SXNativeChecks.h"
#import "SXStore.h"
#import "SXUI.h"
#import "SXPortfolioController.h"
#import "SXReportController.h"

#if DEBUG
@interface SXStore (SXCheckPersistence)
- (BOOL)persist;
@end
@interface SXPortfolioController (SXCheckEdit)
- (void)saveRecord:(NSDictionary *)record cash:(BOOL)cash original:(NSDictionary *)original;
@end
@interface SXRestoreCheckStore : SXStore
@property(nonatomic) BOOL failWrite;
@property(nonatomic) BOOL sawClearedError;
@property(nonatomic) BOOL writeFixtureFiles;
@end
@implementation SXRestoreCheckStore
- (BOOL)persist {
    self.sawClearedError = [self valueForKey:@"persistenceError"] == nil;
    if (self.failWrite) {
        NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError userInfo:@{NSLocalizedDescriptionKey:@"QA simulated disk full"}];
        [self setValue:error forKey:@"lastWriteError"];
        [self setValue:error.localizedDescription forKey:@"persistenceError"];
        return NO;
    }
    if(self.writeFixtureFiles){if([self valueForKey:@"persistenceError"])return NO;NSError *error=nil;NSData *data=[self exportProfileData:&error];BOOL ok=data&&[data writeToURL:[self valueForKey:@"profileURL"] options:NSDataWritingAtomic error:&error];if(!ok){[self setValue:error forKey:@"lastWriteError"];[self setValue:error.localizedDescription?:@"QA write failed" forKey:@"persistenceError"];}return ok;}
    return [super persist];
}
@end

static void SXWriteCheckResult(NSArray *failures, NSInteger count) {
    NSString *directory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSDictionary *result = @{@"passed":@(failures.count == 0), @"checks":@(count), @"failures":failures, @"nativeUI":@YES};
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[directory stringByAppendingPathComponent:@"native-self-test.json"] atomically:YES];
}
#endif

void SXRunNativeChecks(void) {
#if DEBUG
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--native-self-test"]) return;
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]) {
        SXWriteCheckResult(@[@"Native self-test requires isolated UI fixtures"], 0); return;
    }
    SXStore *store = [SXStore sharedStore]; NSMutableArray *failures = [NSMutableArray new];
    __block NSInteger count = 0;
    void (^check)(BOOL, NSString *) = ^(BOOL passed, NSString *message) { count++; if (!passed) [failures addObject:message]; };
    NSData *before = [store exportProfileData:nil];
    NSArray *invalid = @[
        @{@"version":@1, @"values":@{@"settings":@[]}},
        @{@"version":@1, @"values":@{@"account.v1":@{@"cash":NSNull.null, @"positions":@[]}}},
        @{@"version":@1, @"values":@{@"note.AMD":NSNull.null}},
        @{@"version":@1, @"values":@{@"account.currency":@"EUR"}},
        @{@"version":@1, @"values":@{@"account.v1":@{@"cash":@[], @"positions":@[@{@"id":@"bad", @"code":@"AMD", @"quantity":@"two", @"cost":@100, @"currency":@"USD"}]}}}
    ];
    for (NSDictionary *profile in invalid) {
        NSError *error = nil;
        check(![store importProfile:profile replace:YES error:&error] && [[store exportProfileData:nil] isEqual:before], @"Malformed profile changed native records");
    }
    NSDictionary *cashRow = @{@"id":@"duplicate", @"amount":@100, @"currency":@"USD", @"date":@"2026-11-14"};
    NSDictionary *positionRow = @{@"id":@"duplicate", @"code":@"AMD", @"quantity":@2, @"cost":@100, @"currency":@"USD"};
    for (NSDictionary *account in @[@{@"cash":@[cashRow, cashRow], @"positions":@[]}, @{@"cash":@[], @"positions":@[positionRow, positionRow]}]) {
        NSError *error = nil; NSDictionary *profile = @{@"version":@1, @"values":@{@"account.v1":account}};
        check(![store importProfile:profile replace:YES error:&error] && [[store exportProfileData:nil] isEqual:before], @"Duplicate account IDs were accepted or changed records");
    }
    check(!SXFiniteNumber(@YES) && !SXFiniteNumber(@"100") && [SXMoney(@100, @"TWD") hasPrefix:@"NT$"], @"Native numeric formatting guard failed");
    NSData *archiveBefore = [NSJSONSerialization dataWithJSONObject:store.runs options:NSJSONWritingSortedKeys error:nil];
    BOOL pinnedBefore = [store isPinned:@"qa-amd"];
    [store togglePin:@"qa-amd"];
    NSData *archiveAfter = [NSJSONSerialization dataWithJSONObject:store.runs options:NSJSONWritingSortedKeys error:nil];
    check([archiveBefore isEqual:archiveAfter], @"Pinning changed archived research bytes");
    check([store isPinned:@"qa-amd"] != pinnedBefore, @"Pinning did not change only the preference");
    [store togglePin:@"qa-amd"];

    // Persistence injections use a separate fixture store and a random temp
    // directory. The shared profile URL and user record files are never changed.
    SXRestoreCheckStore *recovery = [SXRestoreCheckStore new];
    NSURL *directory = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[@"Shixu-Recovery-Check-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSError *setupError = nil;
    BOOL madeDirectory = [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionComplete} error:&setupError];
    NSURL *profileURL = [directory URLByAppendingPathComponent:@"fixture-profile.json"];
    NSData *originalFile = [@"fixture original profile bytes" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL madeFile = madeDirectory && [originalFile writeToURL:profileURL options:NSDataWritingAtomic error:&setupError];
    check(madeFile, @"Could not prepare isolated recovery fixture");
    if (madeFile) {
        [recovery setValue:profileURL forKey:@"profileURL"];
        NSDictionary *valid = @{@"version":@1, @"values":@{@"watch":@[@"NVDA"], @"settings":@{@"theme":@"light"}}};
        [recovery setValue:@"QA unreadable original file" forKey:@"persistenceError"];
        NSError *restoreError = nil;
        check([recovery importProfile:valid replace:YES error:&restoreError], @"Valid restore was blocked by the prior persistence error");
        check(recovery.sawClearedError && recovery.persistenceError == nil && [recovery.profile isEqual:valid[@"values"]], @"Successful recovery did not clear the old error and restore the profile");
        NSArray<NSURL *> *backups = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory includingPropertiesForKeys:nil options:0 error:nil];
        BOOL foundOriginalCopy = NO;
        for (NSURL *url in backups) if ([url.lastPathComponent hasPrefix:@"before-import-"] && [[NSData dataWithContentsOfURL:url] isEqual:originalFile]) foundOriginalCopy = YES;
        check(foundOriginalCopy, @"Recovery did not preserve an exact original-file copy before replacement");
        NSData *recoveredBytes = [recovery exportProfileData:nil];
        [recovery setValue:@"QA pre-existing persistence error" forKey:@"persistenceError"];
        recovery.failWrite = YES; restoreError = nil;
        NSDictionary *replacement = @{@"version":@1, @"values":@{@"watch":@[@"AMD"]}};
        check(![recovery importProfile:replacement replace:YES error:&restoreError] && [[recovery exportProfileData:nil] isEqual:recoveredBytes], @"Failed restore changed the prior in-memory records");
        check([recovery.persistenceError isEqual:@"QA pre-existing persistence error"], @"Failed restore discarded the pre-existing persistence error");
        check([restoreError.userInfo[NSUnderlyingErrorKey] code] == NSFileWriteOutOfSpaceError && [restoreError.localizedDescription isEqual:@"QA simulated disk full"], @"Failed restore hid the actual new write error");
        check([[NSData dataWithContentsOfURL:profileURL] isEqual:originalFile], @"Failed restore overwrote the original fixture file");
        recovery.failWrite = NO; [recovery setValue:nil forKey:@"persistenceError"];
        id exported = [NSJSONSerialization JSONObjectWithData:recoveredBytes options:0 error:nil];
        NSData *compact = [NSJSONSerialization dataWithJSONObject:exported options:NSJSONWritingSortedKeys error:nil];
        check([recoveredBytes isEqual:compact], @"Profile export added pretty-print expansion to the import size boundary");

        NSDictionary *original = @{@"id":@"edit-check", @"code":@"AMD", @"quantity":@1, @"cost":@100, @"currency":@"USD"};
        NSMutableDictionary *current = [original mutableCopy]; current[@"quantity"] = @2;
        NSDictionary *updatedProfile = @{@"version":@1, @"values":@{@"account.v1":@{@"cash":@[], @"positions":@[current]}}};
        NSError *editSetupError = nil; BOOL editSetup = [recovery importProfile:updatedProfile replace:YES error:&editSetupError];
        SXPortfolioController *controller = [SXPortfolioController new]; [controller setValue:recovery forKey:@"store"];
        NSData *editBefore = [recovery exportProfileData:nil];
        NSMutableDictionary *edited = [original mutableCopy]; edited[@"quantity"] = @3;
        [controller saveRecord:edited cash:NO original:original];
        check(editSetup && [[recovery exportProfileData:nil] isEqual:editBefore], @"A stale position form overwrote a newer restored record");
        recovery.failWrite=YES;[recovery setValue:nil forKey:@"persistenceError"];
        NSData *runBefore=[recovery exportProfileData:nil];NSDictionary *pending=@{@"id":NSUUID.UUID.UUIDString,@"code":@"AMD",@"status":@"pending"};
        check(![recovery upsertRun:pending]&&[[recovery exportProfileData:nil] isEqual:runBefore],@"Failed request-ID persistence reported success or changed records");

        SXRestoreCheckStore *workspaces=[SXRestoreCheckStore new];workspaces.writeFixtureFiles=YES;
        [workspaces setValue:directory forKey:@"profileDirectoryURL"];[workspaces setValue:[directory URLByAppendingPathComponent:@"profile-v1.json"] forKey:@"profileURL"];[workspaces setValue:nil forKey:@"activeProfileUserID"];[workspaces setValue:nil forKey:@"persistenceError"];
        [workspaces setValue:[@{@"watch":@[@"AMD"]} mutableCopy] forKey:@"values"];
        NSError *switchError=nil;
        check([workspaces activateProfileForUserID:@"qa-account-A" error:&switchError]&&workspaces.profile.count==0,@"First account inherited anonymous records");
        check([workspaces setProfileValue:@[@"NVDA"] forKey:@"watch"],@"Could not save isolated account A");
        check([workspaces activateProfileForUserID:@"qa-account-B" error:&switchError]&&workspaces.profile.count==0,@"Account B inherited account A records");
        check([workspaces setProfileValue:@[@"2330"] forKey:@"watch"],@"Could not save isolated account B");
        NSURL *bURL=[workspaces valueForKey:@"profileURL"];
        check(![bURL.lastPathComponent containsString:@"qa-account-B"]&&[bURL.lastPathComponent hasPrefix:@"account-"],@"Account filename exposed an unhashed identity");
        check([workspaces activateProfileForUserID:@"qa-account-A" error:&switchError]&&[workspaces.watchCodes isEqual:@[@"NVDA"]],@"Returning to A did not restore only A records");
        check([workspaces activateProfileForUserID:nil error:&switchError]&&[workspaces.watchCodes isEqual:@[@"AMD"]],@"Sign-out did not restore anonymous records");
        check([workspaces activateProfileForUserID:@"qa-account-B" error:&switchError]&&[workspaces.watchCodes isEqual:@[@"2330"]],@"Returning to B did not preserve its records");
        check([workspaces activateProfileForUserID:@"qa-account-C" error:&switchError]&&[workspaces copyLocalProfileToActiveAccount:&switchError]&&[workspaces.watchCodes isEqual:@[@"AMD"]],@"Explicit anonymous-to-empty-account copy failed");
        check(![workspaces copyLocalProfileToActiveAccount:&switchError],@"Explicit copy overwrote a nonempty account workspace");
        check([workspaces activateProfileForUserID:@"qa-account-A" error:&switchError],@"Could not reopen A for switch-failure check");
        NSData *aBefore=[workspaces exportProfileData:nil];NSData *corrupt=[@"not a JSON profile" dataUsingEncoding:NSUTF8StringEncoding];[corrupt writeToURL:bURL atomically:YES];
        check(![workspaces activateProfileForUserID:@"qa-account-B" error:&switchError]&&[workspaces.activeProfileUserID isEqual:@"qa-account-A"]&&[[workspaces exportProfileData:nil] isEqual:aBefore]&&[[NSData dataWithContentsOfURL:bURL] isEqual:corrupt],@"Failed target load changed identity or overwrote a workspace");
        workspaces.failWrite=YES;switchError=nil;
        check(![workspaces activateProfileForUserID:nil error:&switchError]&&[workspaces.activeProfileUserID isEqual:@"qa-account-A"]&&[[workspaces exportProfileData:nil] isEqual:aBefore],@"Failed current-profile save switched identity or changed records");
    }
    [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
    NSDictionary *originalRun=store.runs.firstObject;NSMutableDictionary *altered=[originalRun mutableCopy];altered[@"result"]=@{@"summary":@"Untrusted replacement"};check(![store upsertRun:altered]&&[store.runs.firstObject isEqual:originalRun],@"A late response changed completed research or reported success");
    check([store upsertRun:originalRun],@"Identical completed archive was not acknowledged");NSMutableDictionary *downgrade=[originalRun mutableCopy];downgrade[@"status"]=@"pending";check(![store upsertRun:downgrade],@"Completed research accepted a downgraded status");
    NSMutableDictionary *plan=[originalRun mutableCopy];plan[@"id"]=@"qa-plan-1";plan[@"code"]=@"AMD";plan[@"kind"]=@"plan";
    check([SXReportController archiveNexaRun:plan forCode:@"AMD" requestID:@"qa-plan-1"],@"Native NEXA did not archive a completed plan");
    NSMutableDictionary *second=[plan mutableCopy];second[@"id"]=@"qa-plan-2";check([SXReportController archiveNexaRun:second forCode:@"AMD" requestID:@"qa-plan-2"],@"Native NEXA did not preserve successive plan versions");
    NSDictionary *savedPlans=[store valueForProfileKey:@"nexa.plans" fallback:@{}];check([savedPlans[@"AMD"][@"history"] containsObject:plan],@"Native NEXA dropped its prior original snapshot");
    NSData *planBefore=[store exportProfileData:nil];NSMutableDictionary *changedPlan=[second mutableCopy];changedPlan[@"result"]=@{@"summary":@"Changed original"};check(![SXReportController archiveNexaRun:changedPlan forCode:@"AMD" requestID:@"qa-plan-2"]&&[[store exportProfileData:nil] isEqual:planBefore],@"Native NEXA accepted a changed historical result");
    NSDictionary *initialProfile=[NSJSONSerialization JSONObjectWithData:before options:0 error:nil];check([store importProfile:initialProfile replace:YES error:nil],@"Fixture checks did not restore the original isolated records");
    [store refreshQuotesForCodes:@[@"AMD", @"NVDA", @"2330"] completion:^{
        check([store.quotes[@"AMD"][@"price"] doubleValue] == 120, @"Native quote pipeline failed");
        check([store.quotes[@"2330"][@"currency"] isEqual:@"TWD"], @"Native quote currency isolation failed");
        SXWriteCheckResult(failures, count);
    }];
#endif
}
