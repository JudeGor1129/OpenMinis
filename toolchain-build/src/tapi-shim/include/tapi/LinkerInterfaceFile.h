//===- tapi-shim/include/tapi/LinkerInterfaceFile.h -------------*- C++ -*-===//
//
// Part of the OpenMinis embedded toolchain. Derived from apple-libtapi
// (Apache-2.0 WITH LLVM-exception); see ../../README.md.
//
// The linker-facing view of a text-based stub (.tbd), resolved for one
// architecture and one deployment target. This is the exact surface the
// pinned ld64 (cctools-port 904de2a) calls when TAPI_SUPPORT is defined;
// nothing outside it is declared, so an API ld64 does not use cannot drift.
//
//===----------------------------------------------------------------------===//
#ifndef TAPI_LINKER_INTERFACE_FILE_H
#define TAPI_LINKER_INTERFACE_FILE_H

#include <memory>
#include <stdint.h>
#include <string>
#include <tapi/Defines.h>
#include <utility>
#include <vector>

// Same as libtapi: spelled out instead of pulling in <mach/machine.h>, so the
// shim also builds on the Linux host that runs its unit test. On Darwin the
// mach typedefs are `integer_t`, i.e. int, so the redeclaration is identical.
using cpu_type_t = int;
using cpu_subtype_t = int;

TAPI_NAMESPACE_V1_BEGIN

class PackedVersion32;
class Symbol;

enum ParsingFlags : unsigned {
  None = 0,
  ExactCpuSubType = 1U << 0,
  DisallowWeakImports = 1U << 1,
};

inline ParsingFlags operator|(ParsingFlags lhs, ParsingFlags rhs) noexcept {
  return static_cast<ParsingFlags>(static_cast<unsigned>(lhs) |
                                   static_cast<unsigned>(rhs));
}

inline ParsingFlags operator|=(ParsingFlags &lhs, ParsingFlags rhs) noexcept {
  lhs = lhs | rhs;
  return lhs;
}

class TAPI_PUBLIC LinkerInterfaceFile {
public:
  static std::vector<std::string> getSupportedFileExtensions() noexcept;

  /// True when `data` parses as a text-based stub this build understands.
  static bool isSupported(const std::string &path, const uint8_t *data,
                          size_t size) noexcept;

  static bool shouldPreferTextBasedStubFile(const std::string &path) noexcept;
  static bool areEquivalent(const std::string &tbdPath,
                            const std::string &dylibPath) noexcept;

  /// Parses `path` and resolves it for one cpu type/subtype. Returns nullptr
  /// and fills `errorMessage` on failure. The caller owns the result.
  static LinkerInterfaceFile *
  create(const std::string &path, cpu_type_t cpuType, cpu_subtype_t cpuSubType,
         ParsingFlags flags, PackedVersion32 minOSVersion,
         std::string &errorMessage) noexcept;

  const std::vector<uint32_t> &getPlatformSet() const noexcept;
  const std::vector<std::pair<uint32_t, PackedVersion32>> &
  getPlatformsAndMinDeployment() const noexcept;

  const std::string &getInstallName() const noexcept;
  bool isInstallNameVersionSpecific() const noexcept;
  PackedVersion32 getCurrentVersion() const noexcept;
  PackedVersion32 getCompatibilityVersion() const noexcept;
  unsigned getSwiftVersion() const noexcept;
  bool hasTwoLevelNamespace() const noexcept;
  bool isApplicationExtensionSafe() const noexcept;
  bool isNotForDyldSharedCache() const noexcept;
  bool hasAllowableClients() const noexcept;
  bool hasReexportedLibraries() const noexcept;
  bool hasWeakDefinedExports() const noexcept;
  const std::string &getParentFrameworkName() const noexcept;

  const std::vector<std::string> &allowableClients() const noexcept;
  const std::vector<std::string> &reexportedLibraries() const noexcept;
  const std::vector<std::string> &rPaths() const noexcept;
  const std::vector<std::string> &relinkedLibraries() const noexcept;
  const std::vector<std::string> &ignoreExports() const noexcept;
  const std::vector<Symbol> &exports() const noexcept;
  const std::vector<Symbol> &undefineds() const noexcept;
  const std::vector<std::string> &inlinedFrameworkNames() const noexcept;

  /// Resolves one document of a multi-document .tbd (libSystem.B.tbd carries
  /// 38 of them) for the given cpu. The caller owns the result.
  LinkerInterfaceFile *
  getInlinedFramework(const std::string &installName, cpu_type_t cpuType,
                      cpu_subtype_t cpuSubType, ParsingFlags flags,
                      PackedVersion32 minOSVersion,
                      std::string &errorMessage) const noexcept;

  ~LinkerInterfaceFile() noexcept;
  LinkerInterfaceFile(const LinkerInterfaceFile &) noexcept = delete;
  LinkerInterfaceFile &operator=(const LinkerInterfaceFile &) noexcept = delete;
  LinkerInterfaceFile(LinkerInterfaceFile &&) noexcept;
  LinkerInterfaceFile &operator=(LinkerInterfaceFile &&) noexcept;

private:
  LinkerInterfaceFile() noexcept;

  class Impl;
  std::unique_ptr<Impl> _pImpl;
};

TAPI_NAMESPACE_V1_END

#endif // TAPI_LINKER_INTERFACE_FILE_H
