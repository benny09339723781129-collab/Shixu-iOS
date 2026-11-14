#import "SXNativeChecks.h"
#import "SXStore.h"
#import "SXUI.h"
void SXRunNativeChecks(void){
#if DEBUG
 if(![NSProcessInfo.processInfo.arguments containsObject:@"--native-self-test"])return;
 SXStore *store=[SXStore sharedStore];NSMutableArray *failures=[NSMutableArray new];NSData *before=[store exportProfileData:nil];
 NSArray *invalid=@[@{@"version":@1,@"values":@{@"settings":@[]}},@{@"version":@1,@"values":@{@"account.v1":@{@"cash":NSNull.null,@"positions":@[]}}},@{@"version":@1,@"values":@{@"note.AMD":NSNull.null}},@{@"version":@1,@"values":@{@"account.currency":@"EUR"}},@{@"version":@1,@"values":@{@"account.v1":@{@"cash":@[],@"positions":@[@{@"id":@"bad",@"code":@"AMD",@"quantity":@"two",@"cost":@100,@"currency":@"USD"}]}}}];
 for(NSDictionary *profile in invalid){NSError *error=nil;if([store importProfile:profile replace:YES error:&error]||![[store exportProfileData:nil] isEqual:before])[failures addObject:@"Malformed profile changed native records"];}if(SXFiniteNumber(@YES)||SXFiniteNumber(@"100")||![SXMoney(@100,@"TWD") hasPrefix:@"NT$"])[failures addObject:@"Native numeric formatting guard failed"];
 NSArray *archived=store.runs;[store togglePin:@"qa-amd"];if(![store.runs isEqual:archived])[failures addObject:@"Pinning changed archived research"];
 [store refreshQuotesForCodes:@[@"AMD",@"NVDA",@"2330"] completion:^{if([store.quotes[@"AMD"][@"price"] doubleValue]!=120||![store.quotes[@"2330"][@"currency"] isEqual:@"TWD"])[failures addObject:@"Native quote pipeline failed"];
  NSString *directory=[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES) firstObject];NSDictionary *result=@{@"passed":@(failures.count==0),@"checks":@10,@"failures":failures,@"nativeUI":@YES};NSData *json=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];[json writeToFile:[directory stringByAppendingPathComponent:@"native-self-test.json"] atomically:YES];
 }];
#endif
}
