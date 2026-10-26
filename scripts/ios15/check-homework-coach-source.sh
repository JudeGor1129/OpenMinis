#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

policy=src/ios/Views/Chat/Media/HomeworkCoachPolicy.swift
capture=src/ios/Views/Chat/Media/HomeworkCameraCapture.swift
controller=src/ios/Views/Chat/Media/HomeworkCoachController.swift
view=src/ios/Views/Chat/Media/HomeworkCoachView.swift
recognition=src/ios/Views/Chat/Media/HomeworkQuestionRecognizer.swift
project=src/ios/Minis.xcodeproj/project.pbxproj
plist=src/ios/Info.plist

for f in "$policy" "$capture" "$controller" "$view" "$recognition"; do
  [[ -s "$f" ]] || { echo "FAIL: missing homework coach source: $f"; exit 1; }
done
grep -q 'homework.coach.enabled' "$policy"
grep -q 'AVCaptureVideoDataOutput' "$capture"
grep -q 'AVCaptureAudioDataOutput' "$capture"
grep -q 'automaticallyConfiguresApplicationAudioSession = false' "$capture"
grep -q 'setSampleBufferDelegate(nil' "$capture"
grep -q 'homeworkCoach' src/ios/Providers/Voice/AudioSessionCoordinator.swift
grep -q 'homeworkHint' src/ios/Providers/Voice/AudioSessionCoordinator.swift
grep -q 'HomeworkCameraCapture' "$controller"
grep -q 'streamAgentMessage' "$controller"
grep -q 'validatedLesson' "$controller"
grep -q '孩子刚才的语音提问' "$controller"
grep -q 'requiresOnDeviceRecognition' "$recognition"
grep -q 'supportsOnDeviceRecognition || allowNetwork' "$recognition"
grep -q 'appendAudioSampleBuffer' "$recognition"
grep -q 'AVSpeechSynthesizer' "$controller"
grep -q 'NavigationView' "$view"
grep -q 'Toggle("允许语音老师"' src/ios/Views/Settings/ToolsSettingsView.swift
grep -q 'HomeworkCoachView(vm: vm)' src/ios/Views/Chat/AIChatView.swift
grep -q 'HomeworkCameraCapture.swift' "$project"
grep -q 'HomeworkCoachController.swift' "$project"
grep -q 'HomeworkCoachPolicy.swift' "$project"
grep -q 'HomeworkCoachView.swift' "$project"
grep -q 'NSCameraUsageDescription' "$plist"
grep -q 'NSMicrophoneUsageDescription' "$plist"
! grep -q 'RPScreenRecorder' "$capture" "$controller"
! grep -q 'AVAssetWriter' "$capture" "$controller"
git diff --check
printf 'PASS: homework coach source wiring, privacy boundary and iOS15 view guard.\n'
if ! command -v xcrun >/dev/null; then
  echo 'NOTE: no Apple SDK here; macOS CI performs policy tests and type-checking.'
  exit 0
fi
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cp src/ios/MinisTests/Standalone/HomeworkCoachPolicyTests.swift "$out/main.swift"
xcrun swiftc "$policy" "$out/main.swift" -o "$out/homework-policy-test"
"$out/homework-policy-test"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos swiftc -typecheck -swift-version 6 \
  -target arm64-apple-ios15.0 -sdk "$SDK" \
  scripts/ios15/HomeworkCoachTypecheckSupport.swift \
  "$policy" "$capture" "$recognition" "$controller" "$view"
# Full-app integration is validated by the [ios15-full-build] workflow job.
# Retry marker: voice-teacher 7ed03d8 after run152 hosted-runner capacity cancellation.
echo 'PASS: production policy tests and iOS15 Swift6 coach type-check (integration stubs).'
echo 'NOTE: full-app integration and camera/audio runtime still need the full build and device test.'
