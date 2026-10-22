#!/usr/bin/env bash
#
# fetch-sources.sh — materialise the pinned upstream sources this toolchain
# builds from. Everything is fetched at the exact revision the shipped product
# declares, so the result is reviewable and reproducible.
#
# Pins come from the product's own licence NOTICE and source bundle:
#   LLVM         40f30ea173b50c130c01d843b612f9563ca63930
#   cctools-port 904de2a71d4da6a9b30d2efaf912a10ddc7d9ddb
#
# The arm64e behaviour is not left to chance: the lld Mach-O arm64e backend and
# the NonLazyBind suppression exist only as patches (deps/patches/). Upstream
# LLVM has no arm64e Mach-O backend, which is why an unpatched toolchain cannot
# emit cpusubtype 0x80000002.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/work"
DEPS="$ROOT/deps"

LLVM_COMMIT="${LLVM_COMMIT:-40f30ea173b50c130c01d843b612f9563ca63930}"
CCTOOLS_COMMIT="${CCTOOLS_COMMIT:-904de2a71d4da6a9b30d2efaf912a10ddc7d9ddb}"

mkdir -p "$WORK"

# ---------------------------------------------------------------------------
# cctools-port (Apple ld64 + supporting tools)
# ---------------------------------------------------------------------------
if [ ! -d "$WORK/cctools-port/.git" ]; then
  echo "==> cloning cctools-port"
  git clone https://github.com/tpoechtrager/cctools-port.git "$WORK/cctools-port"
fi
cd "$WORK/cctools-port"
git fetch --all --tags
echo "==> checking out $CCTOOLS_COMMIT"
git checkout --force "$CCTOOLS_COMMIT"
if [ ! -d cctools/ld64/src/ld ]; then
  echo "!! ld64 sources missing after checkout" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Patch inventory check — fail loudly rather than build a silently-degraded
# toolchain that links arm64e as arm64.
# ---------------------------------------------------------------------------
cd "$ROOT"
MISSING=0
for p in llvm-arm64e-twork.diff llvm-pr-188378.diff llvm-pr-188638.diff; do
  if [ ! -f "$DEPS/patches/$p" ]; then
    echo "!! missing patch: deps/patches/$p" >&2
    MISSING=1
  fi
done
if [ "$MISSING" -ne 0 ]; then
  exit 1
fi
echo "==> patch inventory complete"
for p in "$DEPS"/patches/*.diff; do
  echo "   $(basename "$p"): $(wc -l < "$p") lines"
done

echo
echo "==> sources ready in $WORK"
echo "    LLVM commit to check out: $LLVM_COMMIT"
echo "    next: scripts/build-ios-toolchain.sh"
