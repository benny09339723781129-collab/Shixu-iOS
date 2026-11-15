#import <UIKit/UIKit.h>
#import "Native/SXRootController.h"

@interface ShixuSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation ShixuSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [SXRootController new];
    [self.window makeKeyAndVisible];
}
@end

@interface ShixuAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation ShixuAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:session.role];
    configuration.delegateClass = ShixuSceneDelegate.class;
    return configuration;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ShixuAppDelegate.class)); }
}