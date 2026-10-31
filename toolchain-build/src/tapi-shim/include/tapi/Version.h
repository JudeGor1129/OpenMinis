//===- tapi-shim/include/tapi/Version.h -------------------------*- C++ -*-===//
//
// Part of the OpenMinis embedded toolchain. Derived from apple-libtapi
// (Apache-2.0 WITH LLVM-exception); see ../../README.md.
//
// ld64 prints these from `-v` / `-version_details`. The full string names the
// shim honestly so a version report never claims to be Apple's libtapi.
//
//===----------------------------------------------------------------------===//
#ifndef TAPI_VERSION_H
#define TAPI_VERSION_H

#include <string>
#include <tapi/Defines.h>

#define TAPI_VERSION 2.3.0
#define TAPI_VERSION_MAJOR 2U
#define TAPI_VERSION_MINOR 3U
#define TAPI_VERSION_PATCH 0U

namespace tapi {

class TAPI_PUBLIC Version {
public:
  static unsigned getMajor() noexcept;
  static unsigned getMinor() noexcept;
  static unsigned getPatch() noexcept;
  static std::string getAsString() noexcept;
  static std::string getFullVersionAsString() noexcept;
  static bool isAtLeast(unsigned major, unsigned minor = 0,
                        unsigned patch = 0) noexcept;
};

} // end namespace tapi

#endif // TAPI_VERSION_H
