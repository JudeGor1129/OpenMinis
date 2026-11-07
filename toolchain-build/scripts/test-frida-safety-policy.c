#include "FridaSafetyPolicy.h"
#include <assert.h>
#include <stdio.h>

static unsigned checks = 0;
#define CHECK(condition) do { checks++; assert(condition); } while (0)
#define COUNT(a) ((int)(sizeof(a) / sizeof((a)[0])))
static size_t blob(unsigned char *out, int32_t argc, const char *const *argv) {
    const char *path = "/var/jb/usr/sbin/frida-server";
    size_t n = sizeof(argc);
    memcpy(out, &argc, n);
    memcpy(out+n, path, strlen(path)+1); n += strlen(path)+1;
    out[n++] = 0; out[n++] = 0;
    for (int i = 0; i < argc; i++) {
        size_t bytes = strlen(argv[i])+1;
        memcpy(out+n, argv[i], bytes); n += bytes;
    }
    return n;
}
int main(void) {
    const char *valid[] = {"/var/jb/usr/sbin/frida-server", "--ignore-crashes", "--listen=127.0.0.1:27042"};
    const char *shortOptions[] = {"frida-server", "-C", "-l", "127.0.0.1:27042"};
    const char *longSeparate[] = {"frida-server", "--listen", "127.0.0.1:27042", "--ignore-crashes"};
    const char *old[] = {"frida-server"};
    const char *onlyC[] = {"frida-server", "-C"};
    const char *missingC[] = {"frida-server", "-l", "127.0.0.1:27042"};
    const char *external[] = {"frida-server", "-C", "-l", "0.0.0.0:27042"};
    const char *wrongPort[] = {"frida-server", "-C", "--listen=127.0.0.1:27043"};
    const char *trick[] = {"frida-server", "--ignore-crashes=true", "--listen=127.0.0.1:27042"};
    const char *duplicate[] = {"frida-server", "-C", "-C", "--listen=127.0.0.1:27042"};
    const char *device[] = {"frida-server", "-C", "--listen=127.0.0.1:27042", "--device", "local"};
    const char *shell[] = {"dash", "-c", "exec frida-server --ignore-crashes --listen=127.0.0.1:27042"};
    const char *empty[] = {"frida-server", "-C", "-l", ""};
    const char *token[] = {"frida-server", "-C", "--listen=127.0.0.1:27042", "--token=secret-not-logged"};
    CHECK(OpenMinisFridaArgumentsAreGuarded(COUNT(valid), valid));
    CHECK(OpenMinisFridaArgumentsAreGuarded(COUNT(shortOptions), shortOptions));
    CHECK(OpenMinisFridaArgumentsAreGuarded(COUNT(longSeparate), longSeparate));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(old), old));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(onlyC), onlyC));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(missingC), missingC));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(external), external));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(wrongPort), wrongPort));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(trick), trick));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(duplicate), duplicate));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(device), device));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(shell), shell));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(empty), empty));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(COUNT(token), token));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(3, NULL));
    unsigned char input[1024] = {0};
    const char *parsed[OPENMINIS_FRIDA_MAX_ARGUMENTS] = {0};
    int count = 0;
    size_t n = blob(input, COUNT(valid), valid);
    CHECK(OpenMinisFridaParseArguments(input,n,parsed,&count));
    CHECK(count == COUNT(valid));
    CHECK(OpenMinisFridaArgumentsAreGuarded(count,parsed));
    for (size_t i=0;i<n;i++) CHECK(!OpenMinisFridaParseArguments(input,i,parsed,&count));
    CHECK(!OpenMinisFridaParseArguments(NULL,n,parsed,&count));
    CHECK(!OpenMinisFridaParseArguments(input,OPENMINIS_FRIDA_MAX_PROCARGS_BYTES+1,parsed,&count));
    int32_t bad = -1; memcpy(input,&bad,sizeof(bad));
    CHECK(!OpenMinisFridaParseArguments(input,n,parsed,&count));
    bad = OPENMINIS_FRIDA_MAX_ARGUMENTS+1; memcpy(input,&bad,sizeof(bad));
    CHECK(!OpenMinisFridaParseArguments(input,n,parsed,&count));
    n = blob(input, COUNT(missingC), missingC);
    const char env[] = "MODE=--ignore-crashes\0";
    memcpy(input+n, env, sizeof(env));
    CHECK(OpenMinisFridaParseArguments(input,n+sizeof(env),parsed,&count));
    CHECK(!OpenMinisFridaArgumentsAreGuarded(count,parsed));
    CHECK(OpenMinisFridaIsUserAppPath("/private/var/containers/Bundle/Application/UUID/Demo.app/Demo"));
    CHECK(OpenMinisFridaIsUserAppPath("/var/containers/Bundle/Application/UUID/Demo.app/Demo"));
    CHECK(!OpenMinisFridaIsUserAppPath("/System/Library/CoreServices/SpringBoard.app/SpringBoard"));
    CHECK(!OpenMinisFridaIsUserAppPath("/sbin/launchd"));
    CHECK(!OpenMinisFridaIsUserAppPath("/var/containers/Bundle/Application-other/UUID/Demo.app/Demo"));
    CHECK(!OpenMinisFridaIsUserAppPath("/var/containers/Bundle/Application/UUID/../Demo.app/Demo"));
    CHECK(!OpenMinisFridaIsUserAppPath(NULL));
    printf("PASS: %u production Frida safety policy assertions; no server/process access or Frida API executed.\n",checks);
    return 0;
}
