//===- tapi-shim/lib/LinkerInterfaceFile.cpp --------------------*- C++ -*-===//
//
// Part of the OpenMinis embedded toolchain. Derived from apple-libtapi
// src/tapi/tools/libtapi/LinkerInterfaceFile.cpp (Apache-2.0 WITH
// LLVM-exception); see ../README.md.
//
// Why this file exists
// --------------------
// The pinned ld64 reads .tbd stubs only when built with TAPI_SUPPORT, and then
// only through Apple's libtapi C++ API. The embedded toolchain was built
// without it, so every dynamic link failed on device with
//
//     ld: dynamic executables or dylibs must link with libSystem.dylib
//
// because the SDK's libSystem is a .tbd the linker could not open.
//
// libtapi's linker API is itself a thin adapter over llvm/TextAPI, and the
// locked LLVM archive already contains llvm::MachO::TextAPIReader. This file
// keeps libtapi's adapter logic -- architecture selection, $ld$ directives,
// Objective-C symbol expansion, inlined documents -- and swaps only libtapi's
// internal Registry for TextAPIReader. ld64 links against the same LLVM it
// already carries; no second copy of LLVM and no prebuilt binary is added.
//
// Divergences from libtapi, all deliberate:
//   * Readers: TextAPIReader handles TBD v1-v5 (YAML and JSON). libtapi's
//     extra "diagnostic" reader is not applicable to linking.
//   * Symbol flags are masked to the three bits tapi::SymbolFlags defines.
//   * Ignored exports are kept sorted so the export filter is a binary search
//     rather than a linear scan per symbol.
//
//===----------------------------------------------------------------------===//

#include <tapi/tapi.h>

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/TextAPI/Architecture.h"
#include "llvm/TextAPI/ArchitectureSet.h"
#include "llvm/TextAPI/InterfaceFile.h"
#include "llvm/TextAPI/PackedVersion.h"
#include "llvm/TextAPI/Platform.h"
#include "llvm/TextAPI/Symbol.h"
#include "llvm/TextAPI/Target.h"
#include "llvm/TextAPI/TextAPIReader.h"

#include <algorithm>
#include <string>
#include <vector>

using namespace llvm;
using namespace llvm::MachO;

namespace tapi {

// ---------------------------------------------------------------------------
// Version reporting
// ---------------------------------------------------------------------------

unsigned APIVersion::getMajor() noexcept { return TAPI_API_VERSION_MAJOR; }
unsigned APIVersion::getMinor() noexcept { return TAPI_API_VERSION_MINOR; }
unsigned APIVersion::getPatch() noexcept { return TAPI_API_VERSION_PATCH; }

bool APIVersion::isAtLeast(unsigned major, unsigned minor,
                           unsigned patch) noexcept {
  if (TAPI_API_VERSION_MAJOR != major)
    return TAPI_API_VERSION_MAJOR > major;
  if (TAPI_API_VERSION_MINOR != minor)
    return TAPI_API_VERSION_MINOR > minor;
  return TAPI_API_VERSION_PATCH >= patch;
}

bool APIVersion::hasFeature(Feature) noexcept { return false; }
bool APIVersion::hasABI(unsigned abiVersion) noexcept { return abiVersion == 1; }

unsigned Version::getMajor() noexcept { return TAPI_VERSION_MAJOR; }
unsigned Version::getMinor() noexcept { return TAPI_VERSION_MINOR; }
unsigned Version::getPatch() noexcept { return TAPI_VERSION_PATCH; }

std::string Version::getAsString() noexcept {
  return std::to_string(TAPI_VERSION_MAJOR) + "." +
         std::to_string(TAPI_VERSION_MINOR) + "." +
         std::to_string(TAPI_VERSION_PATCH);
}

std::string Version::getFullVersionAsString() noexcept {
  return "OpenMinis tapi-shim " + getAsString() + " (llvm::MachO::TextAPIReader)";
}

bool Version::isAtLeast(unsigned major, unsigned minor, unsigned patch) noexcept {
  if (TAPI_VERSION_MAJOR != major)
    return TAPI_VERSION_MAJOR > major;
  if (TAPI_VERSION_MINOR != minor)
    return TAPI_VERSION_MINOR > minor;
  return TAPI_VERSION_PATCH >= patch;
}

inline namespace v1 {

namespace {

/// Parses "x[.y[.z]]" into a packed version; malformed input yields 0, which
/// never equals a real deployment target, so the directive is simply skipped.
llvm::MachO::PackedVersion parseVersion32(StringRef str) {
  if (str.empty())
    return {};

  SmallVector<StringRef, 3> parts;
  SplitString(str, parts, ".");
  if (parts.empty())
    return {};

  unsigned long long num = 0;
  if (getAsUnsignedInteger(parts[0], 10, num) || num > UINT16_MAX)
    return {};
  uint32_t version = static_cast<uint32_t>(num) << 16;

  if (parts.size() > 1) {
    if (getAsUnsignedInteger(parts[1], 10, num) || num > UINT8_MAX)
      return {};
    version |= static_cast<uint32_t>(num) << 8;
  }
  if (parts.size() > 2) {
    if (getAsUnsignedInteger(parts[2], 10, num) || num > UINT8_MAX)
      return {};
    version |= static_cast<uint32_t>(num);
  }
  return llvm::MachO::PackedVersion(version);
}

/// First architecture in `archs` sharing `requested`'s cpu type.
Architecture findCompatibleArch(ArchitectureSet archs, Architecture requested) {
  auto requestedCPUType = getCPUTypeFromArchitecture(requested).first;
  for (auto arch : archs)
    if (getCPUTypeFromArchitecture(arch).first == requestedCPUType)
      return arch;
  return AK_unknown;
}

Architecture getArchForCPU(cpu_type_t cpuType, cpu_subtype_t cpuSubType,
                           bool enforceCpuSubType, ArchitectureSet archs) {
  auto arch = getArchitectureFromCpuType(static_cast<uint32_t>(cpuType),
                                         static_cast<uint32_t>(cpuSubType));
  if (archs.has(arch))
    return arch;
  if (enforceCpuSubType)
    return AK_unknown;
  return findCompatibleArch(archs, arch);
}

SymbolFlags toTapiFlags(llvm::MachO::SymbolFlags flags) {
  // ThreadLocalValue / WeakDefined / WeakReferenced share bit positions.
  return static_cast<SymbolFlags>(static_cast<unsigned>(flags) & 0x7u);
}

Expected<std::unique_ptr<InterfaceFile>> loadFile(MemoryBufferRef buffer) {
  return TextAPIReader::get(buffer);
}

} // end anonymous namespace

class LinkerInterfaceFile::Impl {
public:
  std::vector<std::pair<uint32_t, PackedVersion32>> _platformAndMinOS;
  std::vector<uint32_t> _platforms;
  std::string _installName;
  std::string _parentFrameworkName;

  llvm::MachO::PackedVersion _currentVersion;
  llvm::MachO::PackedVersion _compatibilityVersion;
  unsigned _swiftABIVersion = 0;
  bool _hasTwoLevelNamespace = false;
  bool _isAppExtensionSafe = false;
  bool _isOSLibNotForSharedCache = false;
  bool _hasWeakDefExports = false;
  bool _installPathOverride = false;

  std::vector<std::string> _reexportedLibraries;
  std::vector<std::string> _allowableClients;
  std::vector<std::string> _ignoreExports; // sorted, unique after init()
  std::vector<std::string> _inlinedFrameworkNames;
  std::vector<std::string> _rPaths;
  std::vector<std::string> _relinkedLibraries;

  std::vector<Symbol> _exports;
  std::vector<Symbol> _undefineds;
  std::shared_ptr<const InterfaceFile> _interface;
  std::vector<std::shared_ptr<const InterfaceFile>> _inlinedFrameworks;

  bool init(const std::shared_ptr<const InterfaceFile> &interface,
            cpu_type_t cpuType, cpu_subtype_t cpuSubType, ParsingFlags flags,
            PackedVersion32 minOSVersion, std::string &errorMessage) noexcept;

private:
  bool isIgnored(StringRef name) const {
    return std::binary_search(_ignoreExports.begin(), _ignoreExports.end(),
                              name.str());
  }

  void addSymbol(std::string name, llvm::MachO::SymbolFlags flags) {
    if (!isIgnored(name))
      _exports.emplace_back(std::move(name), toTapiFlags(flags));
  }

  /// $ld$ <action> $ <condition> $ <symbol-name>, applied only when the
  /// condition names exactly the deployment target being linked for.
  void processSymbol(StringRef name, llvm::MachO::PackedVersion minOSVersion,
                     bool disallowWeakImports) {
    if (!name.starts_with("$ld$"))
      return;

    StringRef action, condition, symbolName;
    std::tie(action, name) = name.drop_front(4).split('$');
    std::tie(condition, symbolName) = name.split('$');
    if (action.empty() || condition.empty() || symbolName.empty())
      return;
    if (!condition.starts_with("os"))
      return;
    if (parseVersion32(condition.drop_front(2)) != minOSVersion)
      return;

    if (action == "hide") {
      _ignoreExports.emplace_back(symbolName.str());
      return;
    }
    if (action == "add") {
      _exports.emplace_back(symbolName.str());
      return;
    }
    if (action == "weak") {
      if (disallowWeakImports)
        _ignoreExports.emplace_back(symbolName.str());
      return;
    }
    if (action == "install_name") {
      _installName = symbolName.str();
      _installPathOverride = true;
      if (_installName == "/System/Library/Frameworks/"
                          "ApplicationServices.framework/Versions/A/"
                          "ApplicationServices")
        _compatibilityVersion = llvm::MachO::PackedVersion(1, 0, 0);
      return;
    }
    if (action == "compatibility_version") {
      _compatibilityVersion = parseVersion32(symbolName);
      return;
    }
  }
};

bool LinkerInterfaceFile::Impl::init(
    const std::shared_ptr<const InterfaceFile> &interface, cpu_type_t cpuType,
    cpu_subtype_t cpuSubType, ParsingFlags flags, PackedVersion32 minOSVersion,
    std::string &errorMessage) noexcept {
  _interface = interface;
  const bool enforceCpuSubType = flags & ParsingFlags::ExactCpuSubType;
  const auto arch = getArchForCPU(cpuType, cpuSubType, enforceCpuSubType,
                                  interface->getArchitectures());
  if (arch == AK_unknown) {
    auto requested = getArchitectureFromCpuType(static_cast<uint32_t>(cpuType),
                                                static_cast<uint32_t>(cpuSubType));
    auto count = interface->getArchitectures().count();
    errorMessage = "missing required architecture " +
                   getArchitectureName(requested).str() + " in file " +
                   interface->getPath().str();
    if (count > 1)
      errorMessage += " (" + std::to_string(count) + " slices)";
    return false;
  }

  // The patch level never participates in $ld$ conditions.
  const llvm::MachO::PackedVersion minOSPacked(minOSVersion.getMajor(),
                                               minOSVersion.getMinor(), 0);

  for (const auto &target : interface->targets()) {
    if (target.Arch != arch || target.Platform == PLATFORM_UNKNOWN)
      continue;
    const uint32_t platform = static_cast<uint32_t>(target.Platform);
    _platforms.emplace_back(platform);
    const PackedVersion32 minDeployment(
        llvm::MachO::PackedVersion(target.MinDeployment).rawValue());
    _platformAndMinOS.emplace_back(platform, minDeployment);
  }
  llvm::sort(_platforms);

  _installName = interface->getInstallName().str();
  _currentVersion = interface->getCurrentVersion();
  _compatibilityVersion = interface->getCompatibilityVersion();
  _hasTwoLevelNamespace = interface->isTwoLevelNamespace();
  _isAppExtensionSafe = interface->isApplicationExtensionSafe();
  _isOSLibNotForSharedCache = interface->isOSLibNotForSharedCache();
  _swiftABIVersion = interface->getSwiftABIVersion();
  for (const auto &umbrella : interface->umbrellas()) {
    if (umbrella.first.Arch != arch)
      continue;
    _parentFrameworkName = umbrella.second;
    break;
  }

  // Pre-scan for linker directives; they decide which exports survive.
  for (const auto *symbol : interface->exports()) {
    if (symbol->getKind() != EncodeKind::GlobalSymbol ||
        !symbol->hasArchitecture(arch))
      continue;
    processSymbol(symbol->getName(), minOSPacked,
                  flags & ParsingFlags::DisallowWeakImports);
  }
  llvm::sort(_ignoreExports);
  _ignoreExports.erase(std::unique(_ignoreExports.begin(), _ignoreExports.end()),
                       _ignoreExports.end());

  const bool useObjC1ABI =
      interface->getPlatforms().count(PLATFORM_MACOS) && arch == AK_i386;

  for (const auto *symbol : interface->symbols()) {
    if (symbol->isUndefined() || !symbol->hasArchitecture(arch))
      continue;

    const std::string name = symbol->getName().str();
    switch (symbol->getKind()) {
    case EncodeKind::GlobalSymbol:
      if (symbol->getName().starts_with("$ld$") &&
          !symbol->getName().starts_with("$ld$previous"))
        continue;
      addSymbol(name, symbol->getFlags());
      break;
    case EncodeKind::ObjectiveCClass:
      if (useObjC1ABI) {
        addSymbol(".objc_class_name_" + name, symbol->getFlags());
      } else {
        addSymbol("_OBJC_CLASS_$_" + name, symbol->getFlags());
        addSymbol("_OBJC_METACLASS_$_" + name, symbol->getFlags());
      }
      break;
    case EncodeKind::ObjectiveCClassEHType:
      addSymbol("_OBJC_EHTYPE_$_" + name, symbol->getFlags());
      break;
    case EncodeKind::ObjectiveCInstanceVariable:
      addSymbol("_OBJC_IVAR_$_" + name, symbol->getFlags());
      break;
    }

    if (symbol->isWeakDefined())
      _hasWeakDefExports = true;
  }

  for (const auto *symbol : interface->undefineds()) {
    if (!symbol->hasArchitecture(arch))
      continue;

    const std::string name = symbol->getName().str();
    const auto tflags = toTapiFlags(symbol->getFlags());
    switch (symbol->getKind()) {
    case EncodeKind::GlobalSymbol:
      _undefineds.emplace_back(name, tflags);
      break;
    case EncodeKind::ObjectiveCClass:
      if (useObjC1ABI) {
        _undefineds.emplace_back(".objc_class_name_" + name, tflags);
      } else {
        _undefineds.emplace_back("_OBJC_CLASS_$_" + name, tflags);
        _undefineds.emplace_back("_OBJC_METACLASS_$_" + name, tflags);
      }
      break;
    case EncodeKind::ObjectiveCClassEHType:
      _undefineds.emplace_back("_OBJC_EHTYPE_$_" + name, tflags);
      break;
    case EncodeKind::ObjectiveCInstanceVariable:
      _undefineds.emplace_back("_OBJC_IVAR_$_" + name, tflags);
      break;
    }
  }

  for (const auto &lib : interface->allowableClients())
    for (const auto &target : lib.targets())
      if (target.Arch == arch)
        _allowableClients.emplace_back(lib.getInstallName().str());

  for (const auto &lib : interface->reexportedLibraries())
    for (const auto &target : lib.targets())
      if (target.Arch == arch)
        _reexportedLibraries.emplace_back(lib.getInstallName().str());

  for (const auto &entry : interface->rpaths())
    if (entry.first.Arch == arch)
      _rPaths.emplace_back(entry.second);

  for (const auto &document : interface->documents()) {
    std::shared_ptr<const InterfaceFile> framework = document;
    _inlinedFrameworkNames.emplace_back(framework->getInstallName().str());
    _inlinedFrameworks.emplace_back(std::move(framework));
  }

  return true;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

LinkerInterfaceFile::LinkerInterfaceFile() noexcept
    : _pImpl{new LinkerInterfaceFile::Impl} {}
LinkerInterfaceFile::~LinkerInterfaceFile() noexcept = default;
LinkerInterfaceFile::LinkerInterfaceFile(LinkerInterfaceFile &&) noexcept =
    default;
LinkerInterfaceFile &
LinkerInterfaceFile::operator=(LinkerInterfaceFile &&) noexcept = default;

std::vector<std::string>
LinkerInterfaceFile::getSupportedFileExtensions() noexcept {
  return {".tbd"};
}

bool LinkerInterfaceFile::isSupported(const std::string &path,
                                      const uint8_t *data,
                                      size_t size) noexcept {
  if (data == nullptr || size == 0)
    return false;
  MemoryBufferRef buffer(
      StringRef(reinterpret_cast<const char *>(data), size), path);
  auto kind = TextAPIReader::canRead(buffer);
  if (!kind) {
    consumeError(kind.takeError());
    return false;
  }
  return true;
}

bool LinkerInterfaceFile::shouldPreferTextBasedStubFile(
    const std::string &) noexcept {
  return true;
}

bool LinkerInterfaceFile::areEquivalent(const std::string &,
                                        const std::string &) noexcept {
  return false;
}

LinkerInterfaceFile *
LinkerInterfaceFile::create(const std::string &path, cpu_type_t cpuType,
                            cpu_subtype_t cpuSubType, ParsingFlags flags,
                            PackedVersion32 minOSVersion,
                            std::string &errorMessage) noexcept {
  auto bufferOrError = MemoryBuffer::getFile(path, /*IsText=*/true,
                                             /*RequiresNullTerminator=*/true);
  if (auto ec = bufferOrError.getError()) {
    errorMessage = path + ": " + ec.message();
    return nullptr;
  }

  auto interfaceOrError = loadFile((*bufferOrError)->getMemBufferRef());
  if (!interfaceOrError) {
    errorMessage = path + ": " + toString(interfaceOrError.takeError());
    return nullptr;
  }

  std::shared_ptr<const InterfaceFile> interface(std::move(*interfaceOrError));
  std::unique_ptr<LinkerInterfaceFile> file(new LinkerInterfaceFile);
  if (!file->_pImpl->init(interface, cpuType, cpuSubType, flags, minOSVersion,
                          errorMessage))
    return nullptr;
  return file.release();
}

const std::vector<std::pair<uint32_t, PackedVersion32>> &
LinkerInterfaceFile::getPlatformsAndMinDeployment() const noexcept {
  return _pImpl->_platformAndMinOS;
}

const std::vector<uint32_t> &
LinkerInterfaceFile::getPlatformSet() const noexcept {
  return _pImpl->_platforms;
}

const std::string &LinkerInterfaceFile::getInstallName() const noexcept {
  return _pImpl->_installName;
}

bool LinkerInterfaceFile::isInstallNameVersionSpecific() const noexcept {
  return _pImpl->_installPathOverride;
}

PackedVersion32 LinkerInterfaceFile::getCurrentVersion() const noexcept {
  return PackedVersion32(_pImpl->_currentVersion.rawValue());
}

PackedVersion32 LinkerInterfaceFile::getCompatibilityVersion() const noexcept {
  return PackedVersion32(_pImpl->_compatibilityVersion.rawValue());
}

unsigned LinkerInterfaceFile::getSwiftVersion() const noexcept {
  return _pImpl->_swiftABIVersion;
}

bool LinkerInterfaceFile::hasTwoLevelNamespace() const noexcept {
  return _pImpl->_hasTwoLevelNamespace;
}

bool LinkerInterfaceFile::isApplicationExtensionSafe() const noexcept {
  return _pImpl->_isAppExtensionSafe;
}

bool LinkerInterfaceFile::isNotForDyldSharedCache() const noexcept {
  return _pImpl->_isOSLibNotForSharedCache;
}

bool LinkerInterfaceFile::hasAllowableClients() const noexcept {
  return !_pImpl->_allowableClients.empty();
}

bool LinkerInterfaceFile::hasReexportedLibraries() const noexcept {
  return !_pImpl->_reexportedLibraries.empty();
}

bool LinkerInterfaceFile::hasWeakDefinedExports() const noexcept {
  return _pImpl->_hasWeakDefExports;
}

const std::string &LinkerInterfaceFile::getParentFrameworkName() const noexcept {
  return _pImpl->_parentFrameworkName;
}

const std::vector<std::string> &
LinkerInterfaceFile::allowableClients() const noexcept {
  return _pImpl->_allowableClients;
}

const std::vector<std::string> &
LinkerInterfaceFile::reexportedLibraries() const noexcept {
  return _pImpl->_reexportedLibraries;
}

const std::vector<std::string> &LinkerInterfaceFile::rPaths() const noexcept {
  return _pImpl->_rPaths;
}

const std::vector<std::string> &
LinkerInterfaceFile::relinkedLibraries() const noexcept {
  return _pImpl->_relinkedLibraries;
}

const std::vector<std::string> &
LinkerInterfaceFile::ignoreExports() const noexcept {
  return _pImpl->_ignoreExports;
}

const std::vector<Symbol> &LinkerInterfaceFile::exports() const noexcept {
  return _pImpl->_exports;
}

const std::vector<Symbol> &LinkerInterfaceFile::undefineds() const noexcept {
  return _pImpl->_undefineds;
}

const std::vector<std::string> &
LinkerInterfaceFile::inlinedFrameworkNames() const noexcept {
  return _pImpl->_inlinedFrameworkNames;
}

LinkerInterfaceFile *LinkerInterfaceFile::getInlinedFramework(
    const std::string &installName, cpu_type_t cpuType,
    cpu_subtype_t cpuSubType, ParsingFlags flags, PackedVersion32 minOSVersion,
    std::string &errorMessage) const noexcept {
  auto it = std::find_if(_pImpl->_inlinedFrameworks.begin(),
                         _pImpl->_inlinedFrameworks.end(),
                         [&](const std::shared_ptr<const InterfaceFile> &f) {
                           return f->getInstallName() == installName;
                         });
  if (it == _pImpl->_inlinedFrameworks.end()) {
    errorMessage = "no such inlined framework: " + installName;
    return nullptr;
  }

  std::unique_ptr<LinkerInterfaceFile> file(new LinkerInterfaceFile);
  if (!file->_pImpl->init(*it, cpuType, cpuSubType, flags, minOSVersion,
                          errorMessage))
    return nullptr;
  return file.release();
}

} // end inline namespace v1
} // end namespace tapi
