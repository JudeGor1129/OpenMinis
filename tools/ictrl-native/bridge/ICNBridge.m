// SPDX-License-Identifier: Apache-2.0
// Stage 1: no hooks that alter SpringBoard behavior, no HID/input, no XCTest.
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <unistd.h>
#import <math.h>
#import "ICNProtocol.h"

typedef CGImageRef (*ICNCaptureFunction)(void);
static ICNCaptureFunction captureScreen;
static BOOL ICNIsLocked(void) {
    // Fail closed if runtime selectors are unavailable. Main-thread only.
    Class cls = NSClassFromString(@"SBLockScreenManager");
    SEL shared = NSSelectorFromString(@"sharedInstance");
    SEL locked = NSSelectorFromString(@"isUILocked");
    if (!cls || ![cls respondsToSelector:shared]) return YES;
    id manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    if (![manager respondsToSelector:locked]) return YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(manager, locked);
}
static NSDictionary *ICNDeviceInfo(void) {
    UIScreen *screen = UIScreen.mainScreen;
    UIDevice *device = UIDevice.currentDevice;
    struct utsname u = {0}; uname(&u);
    UIInterfaceOrientation orientation = UIApplication.sharedApplication.statusBarOrientation;
    return @{ @"name": device.name ?: @"iPhone", @"model": device.model ?: @"iPhone",
        @"os_version": device.systemVersion ?: @"", @"system_version": device.systemVersion ?: @"",
        @"machine": [NSString stringWithUTF8String:u.machine] ?: @"unknown", @"point_width": @(screen.bounds.size.width),
        @"point_height": @(screen.bounds.size.height), @"scale": @(screen.scale),
        @"pixel_width": @(llround(screen.bounds.size.width * screen.scale)),
        @"pixel_height": @(llround(screen.bounds.size.height * screen.scale)),
        @"native_pixel_width": @(screen.nativeBounds.size.width),
        @"native_pixel_height": @(screen.nativeBounds.size.height),
        @"orientation": @(orientation), @"locked": @(ICNIsLocked()),
        @"capture_symbol_available": @(captureScreen != NULL),
        @"server_version": ICN_VERSION, @"protocol_version": @1,
        @"backend": @"native-springboard", @"requires_ddi": @NO,
        @"capabilities": @[@"envelope_v1", @"device_info", @"screenshot"],
        @"stage": @1, @"input_supported": @NO, @"ui_tree_supported": @NO,
        @"hint": @"Read-only native prototype. Screenshot returns its own actual dimensions; no tap/type or UI tree yet." };
}
static BOOL ICNImageNotBlack(CGImageRef image) {
    uint8_t pixels[16 * 16 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, 16, 16, 8, 64, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;
    CGContextDrawImage(ctx, CGRectMake(0,0,16,16), image);
    CGContextRelease(ctx);
    for (size_t i=0; i<sizeof(pixels); i+=4) {
        if (pixels[i] > 4 || pixels[i+1] > 4 || pixels[i+2] > 4) return YES;
    }
    return NO;
}
static NSDictionary *ICNScreenshot(NSDictionary *params) {
    if (ICNIsLocked()) return ICNError(@"device_locked", @"Unlock the device before capture; lock state is fail-closed");
    if (!captureScreen) return ICNError(@"capture_unavailable", @"UICreateScreenImage is not available on this OS");
    NSString *format = params[@"format"] ?: @"jpeg";
    if (![format isKindOfClass:NSString.class] || (![@"jpeg" isEqual:format] && ![@"png" isEqual:format]))
        return ICNError(@"invalid_params", @"format must be jpeg or png");
    id scaleValue = params[@"scale"] ?: @2;
    id qualityValue = params[@"quality"] ?: @0.6;
    if (![scaleValue isKindOfClass:NSNumber.class] || ![qualityValue isKindOfClass:NSNumber.class])
        return ICNError(@"invalid_params", @"scale and quality must be numbers");
    double scale = [scaleValue doubleValue], quality = [qualityValue doubleValue];
    if (!isfinite(scale) || scale < 0.25 || scale > 3 || !isfinite(quality) || quality < 0.1 || quality > 1)
        return ICNError(@"invalid_params", @"scale must be 0.25..3, quality 0.1..1");
    if (params[@"bundle_id"]) return ICNError(@"unsupported", @"App-scoped capture is not implemented in stage 1");
    CGImageRef captured = captureScreen();
    if (!captured) return ICNError(@"capture_failed", @"System capture returned no image");
    UIImage *source = [UIImage imageWithCGImage:captured scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
    CGImageRelease(captured);
    if (!ICNImageNotBlack(source.CGImage)) return ICNError(@"capture_black", @"Capture is black/empty or protected; not reporting success");
    if (ICNIsLocked()) return ICNError(@"device_locked", @"Device locked during capture; image discarded");
    CGSize points = source.size;
    if (points.width <= 0 || points.height <= 0 || points.width * points.height * scale * scale > 12000000)
        return ICNError(@"capture_failed", @"Image dimensions exceed the prototype memory limit");
    UIGraphicsImageRendererFormat *rendererFormat = UIGraphicsImageRendererFormat.preferredFormat;
    rendererFormat.scale = scale;
    rendererFormat.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:points format:rendererFormat];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [source drawInRect:(CGRect){CGPointZero,points}];
    }];
    NSData *data = [format isEqual:@"png"] ? UIImagePNGRepresentation(image) : UIImageJPEGRepresentation(image, quality);
    if (!data || data.length > 3*1024*1024) return ICNError(@"capture_too_large", @"Image exceeds 3 MiB; reduce scale or use JPEG");
    if (ICNIsLocked()) return ICNError(@"device_locked", @"Device locked during encoding; image discarded");
    return @{ @"data": [data base64EncodedStringWithOptions:0], @"format": format,
        @"bytes": @(data.length), @"quality": @(quality), @"scale": @(image.scale),
        @"pixel_width": @(CGImageGetWidth(image.CGImage)), @"pixel_height": @(CGImageGetHeight(image.CGImage)),
        @"point_width": @(points.width), @"point_height": @(points.height),
        @"scope": @"screen", @"backend": @"UICreateScreenImage", @"orientation": @"native-capture",
        @"hint": @"Actual capture pixel dimensions / scale give this image's point space. No coordinate actions supported in stage 1.",
        @"prefer_instead": @"Stage 1 has no accessibility tree; do not call page_source/find_element." };
}
static NSDictionary *ICNApprove(NSDictionary *params) {
    __block BOOL initiallyUnlocked = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{ initiallyUnlocked = !ICNIsLocked(); });
    if (!initiallyUnlocked) return ICNError(@"device_locked", @"Unlock before approving a new client");
    NSString *name = params[@"name"], *fingerprint = params[@"fingerprint"];
    if (![name isKindOfClass:NSString.class] || ![fingerprint isKindOfClass:NSString.class]
        || name.length < 1 || name.length > 64 || fingerprint.length != 8)
        return ICNError(@"invalid_params", @"Invalid pairing display fields");
    NSDictionary *info = @{ (__bridge NSString *)kCFUserNotificationAlertHeaderKey: @"iCTRL Native — 本机授权",
        (__bridge NSString *)kCFUserNotificationAlertMessageKey:
            [NSString stringWithFormat:@"客户端：%@\n指纹：%@\n\n允许读取设备信息和当前屏幕？仅在你刚刚发起配对且指纹一致时允许。", name, fingerprint],
        (__bridge NSString *)kCFUserNotificationDefaultButtonTitleKey: @"拒绝",
        (__bridge NSString *)kCFUserNotificationAlternateButtonTitleKey: @"允许" };
    SInt32 error = 0;
    CFUserNotificationRef notice = CFUserNotificationCreate(NULL, 45, kCFUserNotificationCautionAlertLevel, &error,
                                                           (__bridge CFDictionaryRef)info);
    if (!notice || error) {
        if (notice) CFRelease(notice);
        return ICNError(@"approval_unavailable", @"Cannot display local approval alert");
    }
    CFOptionFlags flags = kCFUserNotificationDefaultResponse;
    SInt32 responseError = CFUserNotificationReceiveResponse(notice, 45, &flags);
    CFRelease(notice);
    __block BOOL unlocked = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{ unlocked = !ICNIsLocked(); });
    return @{ @"approved": @(!responseError && (flags & 3) == kCFUserNotificationAlternateResponse && unlocked) };
}
static NSDictionary *ICNHandleBridge(NSDictionary *request) {
    NSString *method = request[@"method"];
    NSDictionary *params = request[@"params"];
    if (![method isKindOfClass:NSString.class] || ![params isKindOfClass:NSDictionary.class])
        return ICNError(@"invalid_request", @"Invalid bridge request");
    if ([method isEqual:@"approve_pair"]) return ICNApprove(params);
    if (![@[@"info", @"screenshot"] containsObject:method])
        return ICNError(@"unsupported", @"This read-only bridge does not support that method");
    __block NSDictionary *result;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try { result = [method isEqual:@"info"] ? ICNDeviceInfo() : ICNScreenshot(params); }
        @catch (NSException *e) { result = ICNError(@"bridge_exception", @"System API failed; no fallback attempted"); }
    });
    return result;
}
static void ICNRunBridge(void) {
    if (!ICNEnsureStateDirectory() || !ICNSafeStateDirectory()) { NSLog(@"[iCTRL Native] private directory unsafe/missing; bridge not started"); return; }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    ICNSetTimeout(fd, 5);
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, ICN_SOCKET, sizeof(addr.sun_path));
    struct stat existing;
    if (lstat(ICN_SOCKET, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != ICN_MOBILE_UID) { close(fd); return; }
        // A duplicate injection must not steal an active bridge endpoint.
        int probe = socket(AF_UNIX, SOCK_STREAM, 0);
        BOOL live = probe >= 0 && connect(probe, (struct sockaddr *)&addr, sizeof(addr)) == 0;
        if (probe >= 0) close(probe);
        if (live) { close(fd); return; }
        unlink(ICN_SOCKET);
    }
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || chmod(ICN_SOCKET, 0600) || listen(fd, 4)) { close(fd); return; }
    NSLog(@"[iCTRL Native] read-only bridge ready; no XCTest/DDI or touch injection");
    while (1) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) { if (errno == EINTR) continue; break; }
        @autoreleasepool {
            ICNSetTimeout(client, 50);
            if (ICNVerifyPeer(client, YES)) {
                NSDictionary *request = ICNReadFrame(client, 8192);
                if (request) ICNWriteFrame(client, ICNHandleBridge(request));
            }
            close(client);
        }
    }
    close(fd);
}
__attribute__((constructor)) static void ICNInitialize(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"]) return;
    captureScreen = (ICNCaptureFunction)dlsym(RTLD_DEFAULT, "UICreateScreenImage");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ICNRunBridge(); });
}
