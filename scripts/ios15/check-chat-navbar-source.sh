#!/bin/bash
# Source guards only. UIKit lifecycle and rendering must be checked on iOS 15.
set -euo pipefail
cd "$(dirname "$0")/../.."
view=src/ios/Views/Chat/AIChatView.swift
adapter=$(sed -n '/^private struct LegacyChatNavigationBarBackground:/,/^\/\/ MARK: - Chat Trailing/p' "$view")
require() {
    printf '%s\n' "$adapter" | grep -Fq "$1" || {
        printf 'FAIL: navigation appearance adapter missing %s\n' "$1"; exit 1;
    }
}
grep -Fq 'LegacyChatNavigationBarBackground(background: UIColor(ChatColors.background))' "$view"
require 'UIViewControllerRepresentable'
require 'override func viewWillAppear('
require 'override func viewDidAppear('
require 'var ancestor = parent'
require 'navigation.viewControllers.contains(where: { $0 === candidate })'
require 'let item = candidate.navigationItem'
require 'appearance.configureWithOpaqueBackground()'
require 'appearance.backgroundColor = background'
require 'appearance.shadowColor = .clear'
require 'appliedBackground?.isEqual(background) == true'
require 'static func dismantleUIViewController('
require 'controller.restoreAppearance()'
for pair in 'standardAppearance:savedStandard:installedAppearance' \
            'compactAppearance:savedCompact:installedCompact' \
            'scrollEdgeAppearance:savedScrollEdge:installedScrollEdge' \
            'compactScrollEdgeAppearance:savedCompactScrollEdge:installedCompactScrollEdge'; do
    IFS=: read -r property saved installed <<< "$pair"
    require "$saved = item.$property"
    require "item.$property = appearance"
    require "$installed = item.$property"
    require "item.$property === installed"
    require "item.$property = $saved"
done
# Ignore comments when checking for forbidden global/shared-bar mutations.
code=$(printf '%s\n' "$adapter" | sed '/^[[:space:]]*\/\//d')
if printf '%s\n' "$code" | grep -Eq 'UINavigationBar\.appearance\(|navigationBar\.[A-Za-z]+Appearance[[:space:]]*='; then
    echo 'FAIL: navigation adapter mutates a shared/global bar'; exit 1
fi
if printf '%s\n' "$code" | grep -Eq 'setNavigationBarHidden|setViewControllers|setToolbarHidden'; then
    echo 'FAIL: background styling must not change navigation state'; exit 1
fi
echo 'PASS: item-scoped opaque chat navigation background, copied-property ownership, restore and streaming no-op source guards.'
echo 'NOTE: not Swift compilation or proof of push/pop, sheet dismissal, theme or landscape rendering.'
