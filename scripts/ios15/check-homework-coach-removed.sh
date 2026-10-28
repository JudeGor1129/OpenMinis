#!/bin/bash
set -euo pipefail

project=src/ios/Minis.xcodeproj/project.pbxproj
removed=(
  src/ios/Views/Chat/Media/HomeworkCameraCapture.swift
  src/ios/Views/Chat/Media/HomeworkCoachController.swift
  src/ios/Views/Chat/Media/HomeworkCoachPolicy.swift
  src/ios/Views/Chat/Media/HomeworkCoachView.swift
  src/ios/Views/Chat/Media/HomeworkQuestionRecognizer.swift
  src/ios/MinisTests/Standalone/HomeworkCoachPolicyTests.swift
  scripts/ios15/HomeworkCoachTypecheckSupport.swift
)

for path in "${removed[@]}"; do
  [[ ! -e "$path" ]] || { echo "FAIL: removed voice-teacher file still exists: $path"; exit 1; }
done

for path in \
  src/ios/Views/Chat/AIChatView.swift \
  src/ios/Views/Settings/ToolsSettingsView.swift \
  src/ios/Providers/Voice/AudioSessionCoordinator.swift \
  src/ios/Info.plist \
  "$project"; do
  if grep -Eqi 'HomeworkCoach|HomeworkHint|homework[- ]?coach|语音老师|作业陪练' "$path"; then
    echo "FAIL: voice-teacher reference remains in $path"
    grep -Eni 'HomeworkCoach|HomeworkHint|homework[- ]?coach|语音老师|作业陪练' "$path" || true
    exit 1
  fi
done

echo 'PASS: voice teacher removed from UI, settings, audio intents, sources, tests, and project wiring.'
