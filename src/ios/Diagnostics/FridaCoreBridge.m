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
            FridaDeviceList *devices = frida_device_manager_enumerate_devices_sync(manager, NULL, &error);
            gint successfulQueries = 0;
            gint totalProcesses = 0;
            gint printed = 0;
            if (error != NULL) {
                [lines addObject:[NSString stringWithFormat:@"ERROR: Device enumeration: %s", error->message]];
                g_error_free(error);
            } else if (devices != NULL) {
                for (gint d = 0; d < frida_device_list_size(devices); d++) {
                    FridaDevice *device = frida_device_list_get(devices, d);
                    const gchar *deviceID = frida_device_get_id(device);
                    // Only the two built-in on-device endpoints. Never probe
                    // discovered USB devices or arbitrary network endpoints.
                    if (g_strcmp0(deviceID, "local") != 0 && g_strcmp0(deviceID, "socket") != 0) {
                        g_object_unref(device);
                        continue;
                    }
                    [lines addObject:[NSString stringWithFormat:@"Backend: %s (%s)", frida_device_get_name(device), deviceID]];
                    GCancellable *cancel = g_cancellable_new();
                    // Cancellation is cooperative; retain through the delayed
                    // block even when enumeration finishes before the deadline.
                    g_object_ref(cancel);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        g_cancellable_cancel(cancel);
                        g_object_unref(cancel);
                    });
                    FridaProcessQueryOptions *options = frida_process_query_options_new();
                    GError *queryError = NULL;
                    FridaProcessList *processes = frida_device_enumerate_processes_sync(device, options, cancel, &queryError);
                    if (queryError != NULL) {
                        [lines addObject:[NSString stringWithFormat:@"WARNING: Backend query failed: %s", queryError->message]];
                        g_error_free(queryError);
                    } else if (processes != NULL) {
                        successfulQueries++;
                        gint count = frida_process_list_size(processes);
                        totalProcesses += count;
                        [lines addObject:[NSString stringWithFormat:@"Processes: %d. PID\tName (combined output limit: 300)", count]];
                        for (gint i = 0; i < count && printed < 300; i++, printed++) {
                            FridaProcess *process = frida_process_list_get(processes, i);
                            [lines addObject:[NSString stringWithFormat:@"%u\t%s", frida_process_get_pid(process), frida_process_get_name(process)]];
                            g_object_unref(process);
                        }
                        if (count == 0) [lines addObject:@"WARNING: Empty result from this backend; cause undetermined. This does not prove sandbox restrictions or the absence of running processes."];
                    } else {
                        [lines addObject:@"WARNING: Backend returned no process list."];
                    }
                    if (processes != NULL) g_object_unref(processes);
                    g_object_unref(options);
                    g_object_unref(cancel);
                    g_object_unref(device);
                }
            }
            if (devices != NULL) g_object_unref(devices);
            if (successfulQueries == 0) {
                [lines addObject:@"ERROR: No built-in backend completed process enumeration. Review backend errors; server connectivity and permissions are not established."];
            } else if (totalProcesses == 0) {
                [lines addObject:@"WARNING: All successful queries were empty. Process visibility remains unverified; do not claim a specific cause or attach capability."];
            }
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
