#import <UIKit/UIKit.h>
#import "OMToolchain.h"
#include <assert.h>

// Building verifies compilation/linking only. Assertions run on explicit launch.
static void CheckDisabledBridge(void) {
    NSDictionary<NSString *, NSString *> *status = [OMToolchain capabilityStatus];
    assert(([status[@"compiler_linked"] isEqualToString:@"no"]));
    assert(([status[@"state"] isEqualToString:@"unavailable"]));
    NSString *out = nil;
    NSString *err = nil;
    OMToolchainStatus result = [OMToolchain runCC1:@[@"-triple", @"arm64-apple-ios16.0"] stdout:&out stderr:&err];
    assert(result == OMToolchainStatusUnavailable && out.length == 0 && err.length > 0);
    result = [OMToolchain runLinker:@[@"-arch", @"arm64"] stdout:&out stderr:&err];
    assert(result == OMToolchainStatusUnavailable && out.length == 0 && err.length > 0);
    assert(([OMToolchain architectureOfMachOAtPath:@"/nonexistent/OMBridgeSmoke"] == OMOutputArchUnknown));
    NSArray<NSString *> *args = [OMToolchain cc1ArgumentsForSource:@"test.m" outputPath:@"test.o" sysroot:@"/test-sdk" resourceDir:@"/test-resource" archName:@"arm64" minimumIOS:@"16.0"];
    assert(([args containsObject:@"arm64-apple-ios16.0"]));
    assert(([args containsObject:@"/test-resource"]));
}

@interface OMBridgeSmokeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation OMBridgeSmokeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    CheckDisabledBridge();
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:controller.view.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.text = @"Disabled bridge assertions passed.\nLLVM compilation was not tested.";
    [controller.view addSubview:label];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(OMBridgeSmokeDelegate.class));
    }
}
