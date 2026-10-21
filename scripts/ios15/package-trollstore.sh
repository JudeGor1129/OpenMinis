#!/bin/bash
# CI-only TrollStore test package. No developer certificate/profile required.
set -euo pipefail
cd "$(dirname "$0")/../.."
SOURCE=build/ios15/DerivedData/Build/Products/Debug-iphoneos/Minis.app
STAGE=build/ios15/trollstore-stage
OUT=build/ios15/artifacts
[[ -d "$SOURCE" ]] || { echo 'error: built Minis.app missing' >&2; exit 1; }
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$OUT" ci-logs
ditto "$SOURCE" "$STAGE/Payload/Minis.app"
APP="$STAGE/Payload/Minis.app"
PLIST=/usr/libexec/PlistBuddy
minimum="$("$PLIST" -c 'Print :MinimumOSVersion' "$APP/Info.plist")"
[[ "$minimum" == 15.0 ]] || { echo "error: unexpected app minimum OS: $minimum" >&2; exit 1; }
# Live Activities have no iOS 15 runtime. Never lower their Info.plist version.
if [[ -d "$APP/PlugIns" ]]; then
  while IFS= read -r -d '' ext; do
    ext_min="$("$PLIST" -c 'Print :MinimumOSVersion' "$ext/Info.plist")"
    major="${ext_min%%.*}"
    if (( major > 15 )); then
      echo "Removing incompatible extension: $(basename "$ext") (iOS $ext_min)"
      rm -rf "$ext"
    fi
  done < <(find "$APP/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
fi
find "$APP" -name embedded.mobileprovision -delete
# Sign nested Mach-O code first; bundle signing below seals resources last.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    codesign --force --sign - --timestamp=none "$binary"
  fi
done < <(find "$APP" -type f -print0)
while IFS= read -r -d '' framework; do
  codesign --force --sign - --timestamp=none "$framework"
done < <(find "$APP" -depth -type d -name '*.framework' -print0)
if [[ -d "$APP/PlugIns" ]]; then
  while IFS= read -r -d '' ext; do
    case "$(basename "$ext")" in
      MinisShare.appex) ent=src/ios/ShareExtension/ShareExtension.entitlements ;;
      MinisFileProvider.appex) ent=src/ios/FileProvider/FileProvider.entitlements ;;
      *) echo "error: no reviewed entitlements for $ext" >&2; exit 1 ;;
    esac
    codesign --force --sign - --timestamp=none --entitlements "$ent" "$ext"
    codesign --verify --strict "$ext"
  done < <(find "$APP/PlugIns" -maxdepth 1 -type d -name '*.appex' -print0)
fi
codesign --force --sign - --timestamp=none --entitlements src/ios/Minis.entitlements "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" > ci-logs/trollstore-entitlements.plist 2> ci-logs/trollstore-signature.txt
IPA="$OUT/Minis-iOS15-TrollStore-test.ipa"
rm -f "$IPA"
(cd "$STAGE" && /usr/bin/zip -qry -y "$OLDPWD/$IPA" Payload)
unzip -t "$IPA" | tail -1
shasum -a 256 "$IPA" | tee "$OUT/SHA256SUMS.txt"
cat > "$OUT/INSTALL-NOTES.txt" <<'NOTES'
Minis iOS 15 TrollStore TEST build (Debug configuration).
Install the .ipa through TrollStore, not ordinary certificate sideloading.
The package uses ad-hoc signatures; successful CI signing is not an install test.
The iOS 16.2 Live Activity extension is excluded. Apple Weather needs iOS 16+.
Apple-hosted capabilities (push/iCloud/WeatherKit) are not guaranteed by TrollStore.
No extra platform, unsandboxed, or private entitlements have been added.
Test launch, chat sizing/streaming/scrolling, sharing and File Provider on device.
NOTES
echo "IPA ready: $IPA"
