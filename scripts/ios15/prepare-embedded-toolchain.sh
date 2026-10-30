#!/usr/bin/env bash
# Download and re-verify the exact Run7 development kit before App linking.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK="$REPO_ROOT/toolchain-build/verified-toolchain-lock.json"
VERIFY="$REPO_ROOT/scripts/ios15/verify-embedded-toolchain-lock.py"
DEST="${OM_EMBEDDED_TOOLCHAIN_ROOT:-$REPO_ROOT/build/ios15/embedded-toolchain}"
case "$DEST" in
  "$REPO_ROOT"/build/ios15/*) ;;
  *) echo "error: toolchain destination must stay under $REPO_ROOT/build/ios15" >&2; exit 2 ;;
esac
DOWNLOAD_DIR="$REPO_ROOT/build/ios15/embedded-toolchain-download"
mkdir -p "$DOWNLOAD_DIR" "$REPO_ROOT/ci-logs"

lock_value() {
  python3 - "$LOCK" "$@" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for key in sys.argv[2:]:
    value = value[key]
print(value)
PY
}
REPOSITORY="$(lock_value repository)"
ARTIFACT_ID="$(lock_value artifact id)"
ARTIFACT_NAME="$(lock_value artifact name)"

if [[ -n "${OM_EMBEDDED_TOOLCHAIN_ARCHIVE:-}" ]]; then
  ARCHIVE="$OM_EMBEDDED_TOOLCHAIN_ARCHIVE"
  METADATA=""
else
  : "${GH_TOKEN:?GH_TOKEN is required to download the locked toolchain artifact}"
  METADATA="$DOWNLOAD_DIR/$ARTIFACT_NAME.json"
  META_PARTIAL="$METADATA.partial"
  rm -f "$META_PARTIAL"
  curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 2 --retry-all-errors \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPOSITORY/actions/artifacts/$ARTIFACT_ID" \
    --output "$META_PARTIAL"
  mv "$META_PARTIAL" "$METADATA"
  python3 "$VERIFY" "$LOCK" --metadata "$METADATA"

  ARCHIVE="$DOWNLOAD_DIR/$ARTIFACT_NAME.zip"
  PARTIAL="$ARCHIVE.partial"
  rm -f "$PARTIAL"
  curl --fail --location --silent --show-error \
    --retry 5 --retry-delay 2 --retry-all-errors \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$REPOSITORY/actions/artifacts/$ARTIFACT_ID/zip" \
    --output "$PARTIAL"
  mv "$PARTIAL" "$ARCHIVE"
fi

python3 "$VERIFY" "$LOCK" --archive "$ARCHIVE"
TMP="$DEST.tmp.$$"
trap 'rm -rf "$TMP"' EXIT
rm -rf "$TMP"
mkdir -p "$TMP"
unzip -q "$ARCHIVE" -d "$TMP"
python3 "$VERIFY" "$LOCK" --archive "$ARCHIVE" --root "$TMP"

bash "$REPO_ROOT/toolchain-build/verify-artifacts.sh" "$TMP"
command -v xcrun >/dev/null 2>&1 || {
  echo 'error: xcrun is required for locked archive architecture checks' >&2
  exit 2
}
{
  xcrun lipo -info "$TMP/libomllvm-arm64.a"
  xcrun lipo "$TMP/libomllvm-arm64.a" -verify_arch arm64
  xcrun lipo -info "$TMP/libomllvm-arm64e.a"
  xcrun lipo "$TMP/libomllvm-arm64e.a" -verify_arch arm64e
  xcrun lipo -info "$TMP/libomld64.a"
  xcrun lipo "$TMP/libomld64.a" -verify_arch arm64 arm64e
} | tee "$REPO_ROOT/ci-logs/embedded-toolchain-architectures.txt"

rm -rf "$DEST"
mv "$TMP" "$DEST"
trap - EXIT
cp "$LOCK" "$REPO_ROOT/ci-logs/embedded-toolchain-lock.json"
if [[ -n "$METADATA" ]]; then
  cp "$METADATA" "$REPO_ROOT/ci-logs/embedded-toolchain-artifact-metadata.json"
fi
cp "$DEST/enabled-link-check/enabled-link-report.json" \
   "$REPO_ROOT/ci-logs/embedded-toolchain-enabled-link-report.json"
{
  shasum -a 256 "$ARCHIVE"
  shasum -a 256 "$DEST/toolchain.json"
  shasum -a 256 "$DEST/enabled-link-check/enabled-link-report.json"
  shasum -a 256 "$DEST/libomllvm-arm64.a" "$DEST/libomllvm-arm64e.a" "$DEST/libomld64.a"
} | tee "$REPO_ROOT/ci-logs/embedded-toolchain-sha256.txt"

echo "Prepared immutable toolchain artifact $ARTIFACT_ID at $DEST."
echo 'OM_TOOLCHAIN_VERIFIED remains intentionally unset; no runtime probe was executed.'
