// Compile only: checks exported source + generated headers agree sufficiently
// for these includes. Does not link LLVM, compile the bridge or execute code.
#include "llvm/Config/llvm-config.h"
#include "llvm/Config/abi-breaking.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"
#include "clang/Basic/Version.h"
#include "clang/CodeGen/CodeGenAction.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/TextDiagnosticBuffer.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "clang/Lex/Preprocessor.h"
#include "lld/Common/Driver.h"
#include "lld/Common/Version.h"
#include "lld/Common/CommonLinkerContext.h"
#ifdef LLD_HAS_DRIVER
LLD_HAS_DRIVER(macho)
#endif

static_assert(sizeof(decltype(&lld::macho::link)) > 0, "LLD MachO library API missing");
static_assert(LLVM_VERSION_MAJOR > 0, "LLVM generated config missing");
void OMDevHeaderProbe(llvm::raw_ostream &output) {
    output << LLVM_VERSION_MAJOR << '\n';
    (void)clang::getClangFullVersion();
}
