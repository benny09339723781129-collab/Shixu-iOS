#import "SXRootController.h"
#import "SXHomeController.h"
#import "SXMarketController.h"
#import "SXResearchController.h"
#import "SXPortfolioController.h"
#import "SXSettingsController.h"
#import "SXStore.h"
#import "SXAPI.h"
#import "SXSession.h"
#import "SXUI.h"
#import "SXNativeChecks.h"
@implementation SXRootController
- (void)viewDidLoad {
 [super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;self.view.tintColor=[UIColor colorWithRed:.22 green:.54 blue:.40 alpha:1];
 UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];spinner.center=self.view.center;spinner.autoresizingMask=UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin|UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin;[self.view addSubview:spinner];[spinner startAnimating];
 [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(workspaceChanged:) name:SXStoreDidChangeNotification object:[SXStore sharedStore]];
 [[SXAPI sharedAPI] synchronizeLegacyCookies:^{
#if DEBUG
 if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]){[spinner removeFromSuperview];[self buildTabs];SXRunNativeChecks();return;}
#endif
 [[SXAPI sharedAPI] requestPath:@"/api/account/status" method:@"GET" body:nil completion:^(id json,NSInteger status,NSError *error){
  NSError *workspaceError=nil;
  if(!error&&status==200&&[json isKindOfClass:NSDictionary.class]){id user=[json[@"user"] isKindOfClass:NSDictionary.class]?json[@"user"]:@{};NSString *userID=[user[@"id"] isKindOfClass:NSString.class]?user[@"id"]:nil;if([json[@"signedIn"] isEqual:@YES]&&!userID.length)workspaceError=[NSError errorWithDomain:@"SXWorkspace" code:1 userInfo:@{NSLocalizedDescriptionKey:@"帳號身分未確認，保留上次工作區。"}];else [[SXStore sharedStore] activateProfileForUserID:[json[@"signedIn"] isEqual:@YES]?userID:nil error:&workspaceError];}
  [spinner removeFromSuperview];[self buildTabs];
  if(workspaceError)SXShowError(self,@"工作區未切換",workspaceError.localizedDescription);
  NSString *identity=[SXStore sharedStore].activeProfileUserID?:@"__local__";NSString *sourceOwner=[NSUserDefaults.standardUserDefaults stringForKey:@"native-legacy-source-owner"];
  if(!error&&!workspaceError&&!sourceOwner){sourceOwner=identity;[NSUserDefaults.standardUserDefaults setObject:sourceOwner forKey:@"native-legacy-source-owner"];}
  if(!error&&!workspaceError&&[identity isEqual:sourceOwner]&&![[SXStore sharedStore] hasPersonalData]&&![NSUserDefaults.standardUserDefaults boolForKey:@"native-migration-v1"])[[SXSession sharedSession] readLegacyProfileWithCompletion:^(NSDictionary *profile,NSError *migrationError){if(migrationError||![([SXStore sharedStore].activeProfileUserID?:@"__local__") isEqual:identity])return;NSError *importError=nil;if(profile&&[[SXStore sharedStore] importProfile:profile replace:NO error:&importError])[NSUserDefaults.standardUserDefaults setBool:YES forKey:@"native-migration-v1"];if(importError)SXShowError(self,@"舊版資料仍保留",importError.localizedDescription);}];
 }];
 }];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)workspaceChanged:(NSNotification *)notification {if(![notification.userInfo[@"workspaceChanged"] boolValue]||!self.viewControllers.count)return;NSUInteger selected=self.selectedIndex;[self buildTabs];self.selectedIndex=MIN(selected,self.viewControllers.count-1);}

- (void)buildTabs {
 NSArray *controllers=@[[SXHomeController new],[SXMarketController new],[SXResearchController new],[SXPortfolioController new],[SXSettingsController new]];NSArray *titles=@[@"首頁",@"行情",@"研究",@"持股",@"設定"],*icons=@[@"house",@"chart.xyaxis.line",@"sparkles",@"chart.pie",@"gearshape"];
 NSMutableArray *navigation=[NSMutableArray new];for(NSUInteger i=0;i<controllers.count;i++){UIViewController *controller=controllers[i];UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:controller];nav.navigationBar.prefersLargeTitles=YES;nav.tabBarItem=[[UITabBarItem alloc] initWithTitle:titles[i] image:[UIImage systemImageNamed:icons[i]] tag:i];[navigation addObject:nav];}self.viewControllers=navigation;
 NSString *theme=[[SXStore sharedStore] setting:@"theme" fallback:@"system"];self.overrideUserInterfaceStyle=[theme isEqual:@"light"]?UIUserInterfaceStyleLight:([@[@"dark",@"black",@"navy"] containsObject:theme]?UIUserInterfaceStyleDark:UIUserInterfaceStyleUnspecified);
#if DEBUG
 if([NSProcessInfo.processInfo.arguments containsObject:@"--ui-fixtures"]){for(UINavigationController *nav in navigation)nav.viewControllers.firstObject.navigationItem.prompt=@"隔離測試資料 · 原生 iOS 介面";NSArray *args=NSProcessInfo.processInfo.arguments;NSUInteger index=[args indexOfObject:@"--ui-screen"];if(index!=NSNotFound&&index+1<args.count){NSString *screen=args[index+1];NSDictionary *screens=@{@"home":@0,@"market":@1,@"research":@2,@"portfolio":@3,@"settings":@4};self.selectedIndex=[screens[screen] unsignedIntegerValue];if([screen isEqual:@"stock"]){[((UINavigationController *)navigation[1]) pushViewController:[[SXStockController alloc] initWithCode:@"AMD"] animated:NO];self.selectedIndex=1;}if([screen isEqual:@"setup"]){self.selectedIndex=2;[(SXResearchController *)((UINavigationController *)navigation[2]).viewControllers.firstObject openSetupForCode:@"AMD"];}if([screen isEqual:@"report"]){self.selectedIndex=2;[(SXResearchController *)((UINavigationController *)navigation[2]).viewControllers.firstObject openRun:[SXStore sharedStore].runs.firstObject];}}}
#endif
}
@end
