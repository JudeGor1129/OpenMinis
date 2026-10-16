#!/bin/bash
# The app uses the iOS 26.2 SDK while retaining an iOS 15 deployment target.
set -euo pipefail
mkdir -p ci-logs
shopt -s nullglob
best_dir=''
best_score=0
for app in /Applications/Xcode*.app; do
  developer="$app/Contents/Developer"
  tool="$developer/usr/bin/xcodebuild"
  [[ -x "$tool" ]] || continue
  version_output="$(DEVELOPER_DIR="$developer" "$tool" -version)"
  printf '%s\n%s\n' "$app" "$version_output"
  version="$(printf '%s\n' "$version_output" | sed -n 's/^Xcode //p')"
  IFS=. read -r major minor patch <<< "$version"
  minor="${minor:-0}"
  patch="${patch:-0}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || continue
  score=$((10#$major * 10000 + 10#$minor * 100 + 10#$patch))
  if (( score >= 260200 && score > best_score )); then
    best_dir="$developer"
    best_score="$score"
  fi
done
[[ -n "$best_dir" ]] || {
  echo 'error: full app diagnostics require installed Xcode 26.2 or later; refusing the older runner default.' >&2
  exit 1
}
export DEVELOPER_DIR="$best_dir"
printf 'Selected DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR"
: "${GITHUB_ENV:?This script selects Xcode for subsequent GitHub Actions steps}"
printf 'DEVELOPER_DIR=%s\n' "$DEVELOPER_DIR" >> "$GITHUB_ENV"
xcodebuild -version | tee ci-logs/xcode-app.txt
xcrun --sdk iphoneos --show-sdk-version | tee ci-logs/iphoneos-sdk.txt
