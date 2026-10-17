#!/bin/bash
# Compatibility probe only: this does not yet embed Frida into Minis.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION=17.9.10
ASSET="frida-core-devkit-${VERSION}-ios-arm64.tar.xz"
OUT="$ROOT/build/frida-probe"
mkdir -p "$OUT" "$ROOT/ci-logs"
# Authenticate only the GitHub API request, never cross-host asset redirects.
# CI supplies its short-lived read-only token; no token is stored in artifacts.
api_headers=(-H 'Accept: application/vnd.github+json')
if [[ -n "${GH_TOKEN:-}" ]]; then
  api_headers+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi
echo 'Fetching Frida release metadata from GitHub API'
curl --fail-with-body --location --http1.1 --compressed --retry 3 --retry-delay 5 \
  --connect-timeout 60 --max-time 600 \
  "${api_headers[@]}" \
  -D "$OUT/api-headers.txt" \
  "https://api.github.com/repos/frida/frida/releases/tags/$VERSION" -o "$OUT/release.json" || {
    # Only allowlisted HTTP diagnostics; never dump authorization or cookies.
    grep -iE '^(HTTP/|x-ratelimit-|retry-after:)' "$OUT/api-headers.txt" || true
    echo 'error: GitHub release metadata request failed; see release.json for API response' >&2
    exit 1
  }
# Verify the exact asset against the digest GitHub publishes. Fail closed if absent.
python3 - "$OUT/release.json" "$ASSET" "$OUT/asset.txt" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
asset = next(a for a in release['assets'] if a['name'] == sys.argv[2])
digest = asset.get('digest', '')
if not digest.startswith('sha256:') or len(digest) != 71:
    raise SystemExit('No SHA-256 release asset digest; manual provenance review required.')
url = asset['browser_download_url']
if not url.startswith('https://github.com/frida/frida/releases/download/'):
    raise SystemExit('Unexpected release download origin')
with open(sys.argv[3], 'w') as f:
    f.write(url + '\n' + digest.split(':', 1)[1] + '\n')
PY
URL="$(sed -n '1p' "$OUT/asset.txt")"
EXPECTED="$(sed -n '2p' "$OUT/asset.txt")"
curl --fail --location --http1.1 --retry 10 --retry-all-errors --retry-delay 5 \
  --connect-timeout 60 --max-time 1800 \
  -C - "$URL" -o "$OUT/$ASSET"
ACTUAL="$(shasum -a 256 "$OUT/$ASSET" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || { echo 'Frida archive checksum mismatch'; exit 1; }
printf '%s  %s\n' "$ACTUAL" "$ASSET" | tee "$ROOT/ci-logs/frida-checksum.txt"
mkdir -p "$OUT/devkit"
tar -xJf "$OUT/$ASSET" -C "$OUT/devkit"
find "$OUT/devkit" -maxdepth 2 -type f -print
[[ -f "$OUT/devkit/frida-core.h" && -f "$OUT/devkit/libfrida-core.a" ]]
# Keep license notices with the investigated SDK; redistribution remains a review gate.
find "$OUT/devkit" -iname '*license*' -o -iname '*copying*' > "$ROOT/ci-logs/frida-notices.txt"
cat > "$OUT/probe.c" <<'C'
#include "frida-core.h"
int main(void) {
    frida_init();
    FridaDeviceManager *manager = frida_device_manager_new();
    g_object_unref(manager);
    frida_deinit();
    return 0;
}
C
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
  -miphoneos-version-min=15.0 -I"$OUT/devkit" "$OUT/probe.c" \
  "$OUT/devkit/libfrida-core.a" -o "$OUT/frida-link-probe" \
  -lbsm -ldl -lm -lresolv -lpthread \
  -framework Foundation -framework Security -framework CoreFoundation \
  -Wl,-fatal_warnings
file "$OUT/frida-link-probe"
xcrun vtool -show-build "$OUT/frida-link-probe"
echo 'PASS: arm64 iOS 15 link probe only; runtime attach and scripts NOT tested.'
