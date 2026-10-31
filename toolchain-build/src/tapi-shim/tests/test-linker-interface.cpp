//===- tapi-shim/tests/test-linker-interface.cpp ---------------------------===//
//
// Host unit test for the OpenMinis tapi-shim, run against the real
// iPhoneOS SDK libSystem.B.tbd (not a hand-written fixture), so it checks the
// shim against exactly the file the on-device linker has to read.
//
//   clang++ -std=c++17 -I<llvm>/include -I../include \
//       test-linker-interface.cpp ../lib/LinkerInterfaceFile.cpp \
//       -L<llvm>/lib -lLLVM-<ver> -o t && ./t <SDK>/usr/lib/libSystem.B.tbd
//
// Facts asserted below were read out of iPhoneOS16.5.sdk's libSystem.B.tbd:
//   * 38 YAML documents: libSystem.B.dylib plus 37 inlined /usr/lib/system/*.
//   * libkeymgr is re-exported only for armv7/armv7s, never for arm64.
//   * _printf lives in libsystem_c, dyld_stub_binder in libdyld.
//   * libcompiler_rt carries $ld$hide$os3.0$___absvdi2.
//
//===----------------------------------------------------------------------===//

#include <tapi/tapi.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr int kCpuTypeARM64 = 0x0100000C;  // CPU_TYPE_ARM | CPU_ARCH_ABI64
constexpr int kCpuTypeX86_64 = 0x01000007; // CPU_TYPE_X86 | CPU_ARCH_ABI64
constexpr int kCpuTypeARM = 12;            // CPU_TYPE_ARM
constexpr int kSubtypeARM64All = 0;
constexpr int kSubtypeARM64E = 2;
constexpr int kSubtypeARMV7 = 9;
constexpr unsigned kPlatformIOS = 2;

int failures = 0;

void check(bool condition, const std::string &what) {
  std::printf("%s %s\n", condition ? "ok  " : "FAIL", what.c_str());
  if (!condition)
    ++failures;
}

bool contains(const std::vector<std::string> &v, const std::string &s) {
  return std::find(v.begin(), v.end(), s) != v.end();
}

bool exportsSymbol(const tapi::LinkerInterfaceFile &f, const std::string &s) {
  for (const auto &sym : f.exports())
    if (sym.getName() == s)
      return true;
  return false;
}

std::unique_ptr<tapi::LinkerInterfaceFile>
open(const std::string &path, int cpu, int sub, tapi::PackedVersion32 minOS,
     tapi::ParsingFlags flags, std::string &error) {
  error.clear();
  return std::unique_ptr<tapi::LinkerInterfaceFile>(
      tapi::LinkerInterfaceFile::create(path, cpu, sub, flags, minOS, error));
}

std::unique_ptr<tapi::LinkerInterfaceFile>
inlined(const tapi::LinkerInterfaceFile &top, const std::string &name, int sub,
        tapi::PackedVersion32 minOS, std::string &error) {
  error.clear();
  return std::unique_ptr<tapi::LinkerInterfaceFile>(top.getInlinedFramework(
      name, kCpuTypeARM64, sub, tapi::ParsingFlags::None, minOS, error));
}

std::vector<char> readAll(const std::string &path) {
  std::vector<char> data;
  if (FILE *f = std::fopen(path.c_str(), "rb")) {
    char buf[65536];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, f)) > 0)
      data.insert(data.end(), buf, buf + n);
    std::fclose(f);
  }
  return data;
}

} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <SDK>/usr/lib/libSystem.B.tbd\n", argv[0]);
    return 2;
  }
  const std::string tbd = argv[1];
  const tapi::PackedVersion32 ios15(15, 0, 0);
  const tapi::PackedVersion32 ios3(3, 0, 0);
  std::string error;

  std::printf("-- recognition\n");
  {
    auto data = readAll(tbd);
    check(!data.empty(), "fixture is readable");
    check(tapi::LinkerInterfaceFile::isSupported(
              tbd, reinterpret_cast<const uint8_t *>(data.data()), data.size()),
          "isSupported accepts the SDK libSystem.B.tbd");
    const char machO[] = "\xcf\xfa\xed\xfe\x0c\x00\x00\x01 not a stub";
    check(!tapi::LinkerInterfaceFile::isSupported(
              "x.dylib", reinterpret_cast<const uint8_t *>(machO), sizeof machO),
          "isSupported rejects Mach-O bytes");
    check(!tapi::LinkerInterfaceFile::isSupported("empty.tbd", nullptr, 0),
          "isSupported rejects an empty buffer");
    check(tapi::APIVersion::isAtLeast(1, 6) && tapi::APIVersion::isAtLeast(2, 2),
          "API level satisfies every ld64 version gate");
    check(tapi::Version::getFullVersionAsString().find("tapi-shim") !=
              std::string::npos,
          "version string identifies the shim, not Apple libtapi");
  }

  std::printf("-- top-level document, arm64\n");
  auto top = open(tbd, kCpuTypeARM64, kSubtypeARM64All, ios15,
                  tapi::ParsingFlags::None, error);
  check(top != nullptr, "create() resolves arm64 (" + error + ")");
  if (!top) {
    std::printf("\n%d check(s) failed\n", failures + 1);
    return 1;
  }
  check(top->getInstallName() == "/usr/lib/libSystem.B.dylib",
        "install name is /usr/lib/libSystem.B.dylib");
  check(unsigned(top->getCurrentVersion()) == ((1319u << 16) | (100u << 8) | 3u),
        "current version is 1319.100.3");
  check(top->hasTwoLevelNamespace(), "two-level namespace");
  check(top->hasReexportedLibraries(), "has re-exported libraries");
  check(contains(top->reexportedLibraries(), "/usr/lib/system/libsystem_c.dylib"),
        "re-exports libsystem_c for arm64");
  check(contains(top->reexportedLibraries(), "/usr/lib/system/libdyld.dylib"),
        "re-exports libdyld for arm64");
  check(!contains(top->reexportedLibraries(), "/usr/lib/system/libkeymgr.dylib"),
        "does NOT re-export armv7-only libkeymgr for arm64");
  check(top->inlinedFrameworkNames().size() == 37,
        "37 inlined documents (got " +
            std::to_string(top->inlinedFrameworkNames().size()) + ")");
  bool iosPlatform = false;
  for (const auto &p : top->getPlatformsAndMinDeployment())
    iosPlatform |= p.first == kPlatformIOS;
  check(iosPlatform, "platform list contains iOS");
  check(top->getPlatformSet().size() == top->getPlatformsAndMinDeployment().size(),
        "platform set and platform/min-OS list agree");

  std::printf("-- inlined documents\n");
  {
    auto libc = inlined(*top, "/usr/lib/system/libsystem_c.dylib",
                        kSubtypeARM64All, ios15, error);
    check(libc != nullptr, "libsystem_c resolves (" + error + ")");
    if (libc) {
      check(exportsSymbol(*libc, "_printf"), "libsystem_c exports _printf");
      check(libc->getParentFrameworkName() == "System",
            "libsystem_c parent umbrella is System (got '" +
                libc->getParentFrameworkName() + "')");
    }
    auto dyld = inlined(*top, "/usr/lib/system/libdyld.dylib", kSubtypeARM64All,
                        ios15, error);
    check(dyld && exportsSymbol(*dyld, "dyld_stub_binder"),
          "libdyld exports dyld_stub_binder");
    auto missing = inlined(*top, "/usr/lib/system/libnope.dylib",
                           kSubtypeARM64All, ios15, error);
    check(!missing && !error.empty(), "unknown inlined name fails with a message");
  }

  std::printf("-- $ld$ directives\n");
  {
    // Facts read from the SDK document itself: the arm64 slice of
    // libcompiler_rt carries ___chkstk_darwin together with
    // $ld$hide$os10.0$...$ld$hide$os12.1$ for it, while ___absvdi2 exists only
    // in the armv7 slice. The first half of this block therefore proves a hide
    // directive applies at its own deployment target and nowhere else, and the
    // second half proves slice filtering -- both are cases where a shim that
    // ignored $ld$ or ignored the architecture would look correct.
    auto rt15 = inlined(*top, "/usr/lib/system/libcompiler_rt.dylib",
                        kSubtypeARM64All, ios15, error);
    auto rt10 = inlined(*top, "/usr/lib/system/libcompiler_rt.dylib",
                        kSubtypeARM64All, tapi::PackedVersion32(10, 0, 0), error);
    check(rt15 && rt10, "libcompiler_rt resolves for iOS 15 and iOS 10");
    if (rt15 && rt10) {
      check(exportsSymbol(*rt15, "___chkstk_darwin"),
            "iOS 15: ___chkstk_darwin exported");
      check(!contains(rt15->ignoreExports(), "___chkstk_darwin"),
            "iOS 15: no hide directive applies to it");
      check(!exportsSymbol(*rt10, "___chkstk_darwin"),
            "iOS 10.0: ___chkstk_darwin hidden by $ld$hide$os10.0$");
      check(contains(rt10->ignoreExports(), "___chkstk_darwin"),
            "iOS 10.0: ___chkstk_darwin listed in ignoreExports");
      check(!exportsSymbol(*rt15, "___absvdi2"),
            "arm64 slice does not export the armv7-only ___absvdi2");
      bool leaked = false;
      for (const auto &s : rt15->exports())
        leaked |= s.getName().rfind("$ld$", 0) == 0 &&
                  s.getName().rfind("$ld$previous", 0) != 0;
      check(!leaked, "no $ld$ directive leaks into exports");
      check(std::is_sorted(rt10->ignoreExports().begin(),
                           rt10->ignoreExports().end()),
            "ignoreExports is sorted");
    }

    std::string armError;
    std::unique_ptr<tapi::LinkerInterfaceFile> v7(top->getInlinedFramework(
        "/usr/lib/system/libcompiler_rt.dylib", kCpuTypeARM, kSubtypeARMV7,
        tapi::ParsingFlags::None, ios15, armError));
    check(v7 != nullptr, "libcompiler_rt resolves for armv7 (" + armError + ")");
    if (v7) {
      check(exportsSymbol(*v7, "___absvdi2"),
            "iOS 15 armv7: ___absvdi2 exported");
      std::string armError3;
      std::unique_ptr<tapi::LinkerInterfaceFile> v7low(top->getInlinedFramework(
          "/usr/lib/system/libcompiler_rt.dylib", kCpuTypeARM, kSubtypeARMV7,
          tapi::ParsingFlags::None, ios3, armError3));
      check(v7low && !exportsSymbol(*v7low, "___absvdi2"),
            "iOS 3.0 armv7: ___absvdi2 hidden by $ld$hide$os3.0$");
      check(v7low && contains(v7low->ignoreExports(), "___absvdi2"),
            "iOS 3.0 armv7: ___absvdi2 listed in ignoreExports");
    }
  }

  std::printf("-- Objective-C symbol expansion\n");
  {
    size_t classes = 0, metaclasses = 0;
    for (const auto &name : top->inlinedFrameworkNames()) {
      auto doc = inlined(*top, name, kSubtypeARM64All, ios15, error);
      if (!doc)
        continue;
      for (const auto &s : doc->exports()) {
        classes += s.getName().rfind("_OBJC_CLASS_$_", 0) == 0;
        metaclasses += s.getName().rfind("_OBJC_METACLASS_$_", 0) == 0;
      }
    }
    check(classes > 0, "objc-classes expand to _OBJC_CLASS_$_ (" +
                           std::to_string(classes) + ")");
    check(classes == metaclasses, "every class has a matching metaclass");
  }

  std::printf("-- architecture selection\n");
  {
    auto e = open(tbd, kCpuTypeARM64, kSubtypeARM64E, ios15,
                  tapi::ParsingFlags::ExactCpuSubType, error);
    check(e != nullptr, "arm64e resolves with ExactCpuSubType (" + error + ")");
    if (e)
      check(e->getInstallName() == "/usr/lib/libSystem.B.dylib",
            "arm64e sees the same install name");
    auto x = open(tbd, kCpuTypeX86_64, 3, ios15, tapi::ParsingFlags::None, error);
    check(!x, "x86_64 is rejected");
    check(error.find("missing required architecture") != std::string::npos,
          "rejection names the missing architecture");
    auto nofile = open("/nonexistent/libnope.tbd", kCpuTypeARM64,
                       kSubtypeARM64All, ios15, tapi::ParsingFlags::None, error);
    check(!nofile && error.find("/nonexistent/libnope.tbd") != std::string::npos,
          "missing file fails with its path in the message");
  }

  if (failures) {
    std::printf("\n%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("\nall tapi-shim checks passed\n");
  return 0;
}
