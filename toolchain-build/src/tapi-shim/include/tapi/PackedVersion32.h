//===- tapi-shim/include/tapi/PackedVersion32.h -----------------*- C++ -*-===//
//
// Part of the OpenMinis embedded toolchain. Derived from apple-libtapi
// (Apache-2.0 WITH LLVM-exception); see ../../README.md.
//
//===----------------------------------------------------------------------===//
#ifndef TAPI_PACKED_VERSION_32_H
#define TAPI_PACKED_VERSION_32_H

#include <stdint.h>
#include <tapi/Defines.h>

TAPI_NAMESPACE_V1_BEGIN

/// A Mach-O style packed version: xxxx.yy.zz in 16.8.8 bits.
class TAPI_PUBLIC PackedVersion32 {
private:
  uint32_t _version = 0;

public:
  PackedVersion32() = default;
  PackedVersion32(uint32_t rawVersion) : _version(rawVersion) {}
  PackedVersion32(unsigned major, unsigned minor, unsigned patch)
      : _version((major << 16) | ((minor & 0xff) << 8) | (patch & 0xff)) {}

  unsigned getMajor() const { return _version >> 16; }
  unsigned getMinor() const { return (_version >> 8) & 0xff; }
  unsigned getPatch() const { return _version & 0xff; }

  bool operator<(const PackedVersion32 &rhs) const {
    return _version < rhs._version;
  }
  bool operator==(const PackedVersion32 &rhs) const {
    return _version == rhs._version;
  }
  bool operator!=(const PackedVersion32 &rhs) const {
    return _version != rhs._version;
  }

  operator unsigned() const { return _version; }
};

TAPI_NAMESPACE_V1_END

#endif // TAPI_PACKED_VERSION_32_H
