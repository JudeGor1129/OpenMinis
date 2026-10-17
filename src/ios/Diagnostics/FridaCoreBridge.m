#import "FridaCoreBridge.h"

#if __has_include(<frida-core.h>)
#import <frida-core.h>
#define OPENMINIS_HAS_FRIDA_CORE 1
#else
#define OPENMINIS_HAS_FRIDA_CORE 0
#endif

BOOL OpenMinisFridaCoreAvailable(void) {
    return OPENMINIS_HAS_FRIDA_CORE;
}

NSString *OpenMinisFridaCoreStatus(void) {
#if OPENMINIS_HAS_FRIDA_CORE
    // Frida is process-wide: never tear it down between tool calls. All callers
    // use the serial worker below; no work runs on the UI thread.
    static dispatch_once_t once;
    dispatch_once(&once, ^{ frida_init(); });
    FridaDeviceManager *manager = frida_device_manager_new();
    if (manager == NULL) return @"ERROR: Frida device manager initialization failed.";
    GError *error = NULL;
    FridaDeviceList *devices = frida_device_manager_enumerate_devices_sync(manager, NULL, &error);
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"Frida Core %s initialized. No process attached; no scripts executed.", frida_version_string()]];
    if (error != NULL) {
        [lines addObject:[NSString stringWithFormat:@"ERROR: %s", error->message]];
        g_error_free(error);
    } else if (devices != NULL) {
        gint count = frida_device_list_size(devices);
        for (gint i = 0; i < MIN(count, 32); i++) {
            FridaDevice *device = frida_device_list_get(devices, i);
            [lines addObject:[NSString stringWithFormat:@"Device: %s (%s)",
                frida_device_get_name(device), frida_device_get_id(device)]];
            g_object_unref(device);
        }
        [lines addObject:@"Device enumeration is not proof of frida-server connectivity or attach permission."];
    }
    if (devices != NULL) g_object_unref(devices);
    frida_device_manager_close_sync(manager, NULL, NULL);
    g_object_unref(manager);
    return [lines componentsJoinedByString:@"\n"];
#else
    return @"ERROR: Frida Core is not embedded in this build.";
#endif
}

void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *)) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("app.openminis.frida", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        @autoreleasepool {
            NSString *result = OpenMinisFridaCoreStatus();
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}
