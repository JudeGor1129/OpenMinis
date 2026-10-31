//
//  probe-linker-block-capture.mm
//
//  Compile-only probe for the exact shape runLinker uses to call the vendored
//  linker entry point. It is not part of the app; nothing links or runs it.
//
//  Why it exists
//  -------------
//  runLinker builds its argv in the dispatch block, then calls
//  om_ld64_main(argc, argv.data()) from a *nested* block. A captured C++ object
//  is const inside the block, so argv.argv.data() became `const char *const *`,
//  which does not convert to the entry point's `const char *argv[]`:
//
//      error: no matching function for call to 'om_ld64_main'
//      note: 2nd argument ('const char *const *') would lose const qualifier
//
//  Nothing on a machine without the LLVM archives can compile runLinker itself,
//  so that mistake reached a full CI build before it was seen. This file
//  reproduces the shape with stand-ins that need no LLVM, and the
//  runtime-diagnostic source gate compiles it with the iOS SDK, so the same
//  mistake fails locally in seconds instead of after a 30-minute build.
//
//  The stand-ins mirror the members runLinker touches (owned / argv); if the
//  real call stops reaching a non-const data() the gate's source assertion on
//  `argvPointer->argv.data()` fails alongside this probe.
//

#import <Foundation/Foundation.h>

#include <string>
#include <vector>

/// Stand-in for the linker entry point: same parameter types as om_ld64_main.
extern "C" int om_linker_entry_probe(int argc, const char *argv[]);

/// Filled in by the host when linking this probe, never called here.
extern "C" int om_linker_entry_probe(int argc, const char *argv[]) {
    return argc + (argv == NULL ? 1 : 0);
}

struct OMLinkerProbeArgvStorage {
    std::vector<std::string> owned;
    std::vector<const char *> argv;

    OMLinkerProbeArgvStorage() {
        owned.emplace_back("ld");
        owned.emplace_back("-arch");
        owned.emplace_back("arm64");
        for (const std::string &s : owned) argv.push_back(s.c_str());
    }
};

typedef struct { int exitStatus; BOOL internalError; } OMLinkerProbeRun;

/// Same signature and same exception handling as OMRunLinkerCapturing.
static OMLinkerProbeRun OMLinkerProbeCapturing(int (^invoke)(void),
                                               NSString **outText,
                                               NSString **errText) {
    OMLinkerProbeRun run = { 0, NO };
    if (outText) *outText = @"";
    if (errText) *errText = @"";
    @try {
        run.exitStatus = invoke();
    } @catch (NSException *e) {
        run.internalError = YES;
        if (errText) *errText = e.reason;
        return run;
    }
    return run;
}

int main(void) {
    dispatch_queue_t queue = dispatch_queue_create("om.linker.probe", DISPATCH_QUEUE_SERIAL);

    dispatch_sync(queue, ^{
        OMLinkerProbeArgvStorage argv;
        // Captured by value below, so a captured copy would be const here.
        // The pointer keeps the pointee mutable -- this is the fix.
        OMLinkerProbeArgvStorage *argvPointer = &argv;
        __block NSString *capturedOut = @"";
        __block NSString *capturedErr = @"";

        const OMLinkerProbeRun run = OMLinkerProbeCapturing(^int {
            return om_linker_entry_probe(static_cast<int>(argvPointer->owned.size()),
                                         argvPointer->argv.data());
        }, &capturedOut, &capturedErr);
        (void)run;
    });

    return 0;
}
