#!/bin/bash
# CI-only TrollStore test package. No developer certificate/profile required.
set -euo pipefail
cd "$(dirname "$0")/../.."
SOURCE=build/ios15/DerivedData/Build/Products/Release-iphoneos/Minis.app
STAGE=build/ios15/trollstore-stage
OUT=build/ios15/artifacts
[[ -d "$SOURCE" ]] || { echo 'error: built Minis.app missing' >&2; exit 1; }
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$OUT" ci-logs
ditto "$SOURCE" "$STAGE/Payload/Minis.app"
APP="$STAGE/Payload/Minis.app"
HELPER=build/ios15/privileged-helper/minis-privileged-helper
[[ -f "$HELPER" ]] || { echo 'error: system helper build product missing' >&2; exit 1; }
cp "$HELPER" "$APP/minis-privileged-helper"
chmod 0755 "$APP/minis-privileged-helper"
APP_ENT=ci-logs/trollstore-system-access.entitlements
python3 - "$APP_ENT" <<'PY'
import plistlib, sys
with open('src/ios/Minis.entitlements', 'rb') as f: base=plistlib.load(f)
with open('tools/privileged-helper/TrollStoreApp.extra.entitlements', 'rb') as f: base.update(plistlib.load(f))
with open(sys.argv[1], 'wb') as f: plistlib.dump(base, f)
PY
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
# Generic Mach-O signing above strips private helper claims; restore the
# dedicated helper signature before sealing the outer app bundle.
codesign --force --sign - --timestamp=none --identifier com.openminis.app.system-helper \
  --entitlements tools/privileged-helper/Helper.entitlements "$APP/minis-privileged-helper"
codesign --verify --strict "$APP/minis-privileged-helper"
codesign -d --entitlements :- "$APP/minis-privileged-helper" > ci-logs/system-helper-entitlements.plist 2> ci-logs/system-helper-signature.txt
codesign --force --sign - --timestamp=none --entitlements "$APP_ENT" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" > ci-logs/trollstore-entitlements.plist 2> ci-logs/trollstore-signature.txt
python3 scripts/ios15/verify-privileged-entitlements.py ci-logs/trollstore-entitlements.plist ci-logs/system-helper-entitlements.plist
IPA="$OUT/Minis-iOS15-TrollStore-test.ipa"
rm -f "$IPA"
(cd "$STAGE" && /usr/bin/zip -qry -y "$OLDPWD/$IPA" Payload)
unzip -t "$IPA" | tail -1
shasum -a 256 "$IPA" | tee "$OUT/SHA256SUMS.txt"
cat > "$OUT/INSTALL-NOTES.txt" <<'NOTES'
Minis iOS 15 TrollStore TEST build (optimized Release configuration).
Install the .ipa through TrollStore, not ordinary certificate sideloading.
The package uses ad-hoc signatures; successful CI signing is not an install test.
The iOS 16.2 Live Activity extension is excluded. Apple Weather needs iOS 16+.
Apple-hosted capabilities (push/iCloud/WeatherKit) are not guaranteed by TrollStore.
WARNING: dedicated TrollStore privileged package. The GUI requires platform,
persona, no-sandbox, AppDataContainers and AppBundles because a sandboxed GUI
was verified on-device to fail persona spawn with EPERM. ContainerLocator
resolves the existing bundle-ID data container explicitly; normal entitlements
and extensions remain unchanged. GUI stays uid501; only the short-lived helper
requests uid0. The helper has no shell/delete/chmod/chown/launchctl/Frida verbs.
System access is default OFF, foreground-only, path-tiered, confirmed before
write, backed up, audited and rollback-capable. Test launch and existing chat
data before enabling read-only identity verification on the target device.
NOTES
echo "IPA ready: $IPA"
