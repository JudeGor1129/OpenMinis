//===- tapi-shim/include/tapi/Symbol.h --------------------------*- C++ -*-===//
//
// Part of the OpenMinis embedded toolchain. Derived from apple-libtapi
// (Apache-2.0 WITH LLVM-exception); see ../../README.md.
//
//===----------------------------------------------------------------------===//
#ifndef TAPI_SYMBOL_H
#define TAPI_SYMBOL_H

#include <string>
#include <tapi/Defines.h>
#include <utility>

TAPI_NAMESPACE_V1_BEGIN

/// The three flags ld64 consumes. Their bit values match the low bits of
/// llvm::MachO::SymbolFlags, which the shim masks down to before storing.
enum class SymbolFlags : unsigned {
  None = 0,
  ThreadLocalValue = 1U << 0,
  WeakDefined = 1U << 1,
  WeakReferenced = 1U << 2,
};

inline SymbolFlags operator&(const SymbolFlags &lhs,
                             const SymbolFlags &rhs) noexcept {
  return static_cast<SymbolFlags>(static_cast<unsigned>(lhs) &
                                  static_cast<unsigned>(rhs));
}

class TAPI_PUBLIC Symbol {
public:
  template <typename Tp>
  Symbol(Tp &&name, SymbolFlags flags = SymbolFlags::None)
      : _name(std::forward<Tp>(name)), _flags(flags) {}

  inline const std::string &getName() const noexcept { return _name; }
  inline SymbolFlags getFlags() const noexcept { return _flags; }

  inline bool isThreadLocalValue() const noexcept {
    return (_flags & SymbolFlags::ThreadLocalValue) ==
           SymbolFlags::ThreadLocalValue;
  }
  inline bool isWeakDefined() const noexcept {
    return (_flags & SymbolFlags::WeakDefined) == SymbolFlags::WeakDefined;
  }
  inline bool isWeakReferenced() const noexcept {
    return (_flags & SymbolFlags::WeakReferenced) ==
           SymbolFlags::WeakReferenced;
  }

private:
  std::string _name;
  SymbolFlags _flags;
};

TAPI_NAMESPACE_V1_END

#endif // TAPI_SYMBOL_H
