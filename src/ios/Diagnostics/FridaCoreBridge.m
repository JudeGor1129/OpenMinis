#import "FridaCoreBridge.h"

#if __has_include(<frida-core.h>)
#import <frida-core.h>
#define OPENMINIS_HAS_FRIDA_CORE 1
#else
#define OPENMINIS_HAS_FRIDA_CORE 0
#endif

BOOL OpenMinisFridaCoreAvailable(void) {
#if OPENMINIS_HAS_FRIDA_CORE
    return YES;
#else
    return NO;
#endif
}

NSString *OpenMinisFridaCoreStatus(void) {
#if OPENMINIS_HAS_FRIDA_CORE
    @try {
        frida_init();
        FridaDeviceManager *manager = frida_device_manager_new();
        if (manager == NULL) {
            frida_deinit();
            return @"Frida Core 已链接，但设备管理器初始化失败";
        }
        g_object_unref(manager);
        frida_deinit();
        return @"Frida Core 已链接，初始化探测通过；尚未启用进程附加";
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"Frida Core 探测异常：%@", exception.reason ?: @"unknown"];
    }
#else
    return @"Frida Core 未内置；当前为兼容占位状态";
#endif
}
