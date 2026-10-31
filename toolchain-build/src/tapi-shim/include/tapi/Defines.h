//===- tapi-shim/include/tapi/Defines.h -------------------------*- C++ -*-===//
//
// Part of the OpenMinis embedded toolchain. Derived from apple-libtapi
// (Apache-2.0 WITH LLVM-exception); see ../../README.md.
//
//===----------------------------------------------------------------------===//
#ifndef TAPI_DEFINES_H
#define TAPI_DEFINES_H

#define TAPI_INTERNAL tapi::internal
#define TAPI_NAMESPACE_INTERNAL_BEGIN namespace tapi { namespace internal {
#define TAPI_NAMESPACE_INTERNAL_END } }

#define TAPI_NAMESPACE_V1_BEGIN namespace tapi { inline namespace v1 {
#define TAPI_NAMESPACE_V1_END } }

// The shim is linked statically into the host process; nothing is exported
// from a shared object, so default visibility is not required. Keeping the
// macro lets the public headers stay textually identical to libtapi's.
#define TAPI_PUBLIC

#endif // TAPI_DEFINES_H
