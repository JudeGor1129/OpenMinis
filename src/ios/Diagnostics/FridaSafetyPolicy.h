#ifndef OPENMINIS_FRIDA_SAFETY_POLICY_H
#define OPENMINIS_FRIDA_SAFETY_POLICY_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define OPENMINIS_FRIDA_CLIENT_VERSION "17.9.10"
#define OPENMINIS_FRIDA_GUARDED_PREFERENCE "agent.tools.frida.guarded.v1.enabled"
#define OPENMINIS_FRIDA_MAX_ARGUMENTS 128
#define OPENMINIS_FRIDA_MAX_PROCARGS_BYTES (1024U * 1024U)

/* Pure parsing only. No syscall, Frida API, environment logging or execution.
 * KERN_PROCARGS2: native int argc, NUL-terminated executable path, NUL padding,
 * then exactly argc NUL-terminated arguments. Environment bytes are ignored.
 */
static inline int OpenMinisFridaParseArguments(const void *bytes, size_t length,
                                              const char **argv, int *argcOut) {
    int32_t argc = 0;
    if (bytes == NULL || argv == NULL || argcOut == NULL ||
        length <= sizeof(argc) || length > OPENMINIS_FRIDA_MAX_PROCARGS_BYTES) return 0;
    memcpy(&argc, bytes, sizeof(argc));
    if (argc < 1 || argc > OPENMINIS_FRIDA_MAX_ARGUMENTS) return 0;
    const char *cursor = (const char *)bytes + sizeof(argc);
    const char *end = (const char *)bytes + length;
    const char *terminator = (const char *)memchr(cursor, '\0', (size_t)(end - cursor));
    if (terminator == NULL || terminator == cursor) return 0;
    cursor = terminator + 1;
    while (cursor < end && *cursor == '\0') cursor++;
    for (int i = 0; i < argc; i++) {
        if (cursor >= end) return 0;
        terminator = (const char *)memchr(cursor, '\0', (size_t)(end - cursor));
        if (terminator == NULL) return 0;
        argv[i] = cursor;
        cursor = terminator + 1;
    }
    if (argv[0][0] == '\0') return 0;
    *argcOut = (int)argc;
    return 1;
}

/* Deliberately accept only the two reviewed options. Unknown/duplicate options
 * (including --device, TLS/token endpoints and bare --ignore-crashes text
 * embedded in a shell command) fail closed. Never inspect environment bytes.
 */
static inline int OpenMinisFridaArgumentsAreGuarded(int argc, const char *const *argv) {
    if (argv == NULL || argc < 3 || argc > 5 || argv[0] == NULL) return 0;
    const char *name = strrchr(argv[0], '/');
    name = name == NULL ? argv[0] : name + 1;
    if (strcmp(name, "frida-server") != 0) return 0;
    int ignoreCrashes = 0, loopback = 0;
    for (int i = 1; i < argc; i++) {
        if (argv[i] == NULL) return 0;
        if (strcmp(argv[i], "--ignore-crashes") == 0 || strcmp(argv[i], "-C") == 0) {
            if (ignoreCrashes++) return 0;
        } else if (strcmp(argv[i], "--listen=127.0.0.1:27042") == 0) {
            if (loopback++) return 0;
        } else if (strcmp(argv[i], "--listen") == 0 || strcmp(argv[i], "-l") == 0) {
            if (loopback++ || ++i >= argc || argv[i] == NULL ||
                strcmp(argv[i], "127.0.0.1:27042") != 0) return 0;
        } else {
            return 0;
        }
    }
    return ignoreCrashes == 1 && loopback == 1;
}

static inline int OpenMinisFridaIsUserAppPath(const char *path) {
    if (path == NULL) return 0;
    const char *prefix = "/private/var/containers/Bundle/Application/";
    const char *alias = "/var/containers/Bundle/Application/";
    if (strncmp(path, prefix, strlen(prefix)) != 0 &&
        strncmp(path, alias, strlen(alias)) != 0) return 0;
    if (strstr(path, "/../") != NULL || strstr(path, "/./") != NULL ||
        strstr(path, "//") != NULL) return 0;
    const char *app = strstr(path, ".app/");
    return app != NULL && app[5] != '\0';
}
#endif
