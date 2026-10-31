//===- tapi-shim/include/tapi/APIVersion.h ----------------------*- C++ -*-===//
//
// Part of the OpenMinis embedded toolchain. Derived from apple-libtapi
// (Apache-2.0 WITH LLVM-exception); see ../../README.md.
//
// ld64 gates its text-stub support on these numbers:
//   textstub_dylib_file.cpp   TAPI_API_VERSION_MAJOR >= 1, isAtLeast(1, 6)
//                             MAJOR == 2 && MINOR >= 2 -> rPaths() and
//                             getPlatformsAndMinDeployment()
//   Options.cpp               (1,6)+ -> inlined frameworks
// 2.3 is the API level of the libtapi revision this shim follows, and every
// entry point those branches call is implemented in LinkerInterfaceFile.cpp.
//
//===----------------------------------------------------------------------===//
#ifndef TAPI_API_VERSION_H
#define TAPI_API_VERSION_H

#include <tapi/Defines.h>

#define TAPI_API_VERSION_MAJOR 2U
#define TAPI_API_VERSION_MINOR 3U
#define TAPI_API_VERSION_PATCH 0U

namespace tapi {

enum class Feature : unsigned {};

class TAPI_PUBLIC APIVersion {
public:
  static unsigned getMajor() noexcept;
  static unsigned getMinor() noexcept;
  static unsigned getPatch() noexcept;
  static bool isAtLeast(unsigned major, unsigned minor = 0,
                        unsigned patch = 0) noexcept;
  static bool hasFeature(Feature feature) noexcept;
  static bool hasABI(unsigned abiVersion) noexcept;
};

} // end namespace tapi

#endif // TAPI_API_VERSION_H
