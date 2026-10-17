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

static void OpenMinisFridaInitialize(void) {
#if OPENMINIS_HAS_FRIDA_CORE
    static dispatch_once_t once;
    dispatch_once(&once, ^{ frida_init(); });
#endif
}

NSString *OpenMinisFridaCoreStatus(void) {
#if OPENMINIS_HAS_FRIDA_CORE
    // Frida is process-wide: never tear it down between tool calls.
    OpenMinisFridaInitialize();
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

static dispatch_queue_t OpenMinisFridaQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("app.openminis.frida", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *)) {
    dispatch_async(OpenMinisFridaQueue(), ^{
        @autoreleasepool {
            NSString *result = OpenMinisFridaCoreStatus();
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

void OpenMinisFridaProcessesAsync(void (^completion)(NSString *)) {
    dispatch_async(OpenMinisFridaQueue(), ^{
        @autoreleasepool {
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
#if OPENMINIS_HAS_FRIDA_CORE
            // Initialize once without performing another device enumeration.
            OpenMinisFridaInitialize();
            FridaDeviceManager *manager = frida_device_manager_new();
            if (manager == NULL) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(@"ERROR: Frida device manager initialization failed."); });
                return;
            }
            GError *error = NULL;
            FridaDevice *device = frida_device_manager_get_device_by_type_sync(manager, FRIDA_DEVICE_TYPE_LOCAL, 3000, NULL, &error);
            if (device != NULL && error == NULL) {
                FridaProcessQueryOptions *options = frida_process_query_options_new();
                FridaProcessList *processes = frida_device_enumerate_processes_sync(device, options, NULL, &error);
                if (processes != NULL) {
                    gint count = frida_process_list_size(processes);
                    [lines addObject:[NSString stringWithFormat:@"Local processes: %d (showing up to 300). PID\tName", count]];
                    for (gint i = 0; i < MIN(count, 300); i++) {
                        FridaProcess *process = frida_process_list_get(processes, i);
                        [lines addObject:[NSString stringWithFormat:@"%u\t%s", frida_process_get_pid(process), frida_process_get_name(process)]];
                        g_object_unref(process);
                    }
                    g_object_unref(processes);
                } else if (error == NULL) {
                    [lines addObject:@"ERROR: Frida returned no process list."];
                }
                g_object_unref(options);
            }
            if (error != NULL) {
                [lines addObject:[NSString stringWithFormat:@"ERROR: %s", error->message]];
                g_error_free(error);
            } else if (device == NULL) {
                [lines addObject:@"ERROR: No local Frida device available."];
            }
            if (device != NULL) g_object_unref(device);
            frida_device_manager_close_sync(manager, NULL, NULL);
            g_object_unref(manager);
            [lines addObject:@"Read-only enumeration; no process attached or script executed. Visibility is limited by this app's actual privileges; listing does not prove attach permission."];
#else
            [lines addObject:@"ERROR: Frida Core is not embedded in this build."];
#endif
            NSString *result = [lines componentsJoinedByString:@"\n"];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}
