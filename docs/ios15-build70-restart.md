# iOS 15 source baseline restart

## Active source

This directory (`build70-review/OpenMinis-build70`) is the active workspace source for the iOS 15 port.

- Accepted baseline: GitHub Actions iOS 15 diagnostics **#70**.
- Baseline commit: `ad42431ceb96e8bfabc8018b87702bedd72442ae`.
- Run: https://github.com/JudeGor1129/OpenMinis/actions/runs/39122333794
- User decision: discard functional changes from builds 71–88 and resume development from build 70. The previous source directory is historical, not the source for future changes.

Publication preserves Git history without force-pushing. The published source tree must equal build 70 plus the explicitly reviewed changes below. A later commit in the ancestry does NOT mean its implementation was retained.

## Changes after the restart

- Keep build 70's iOS 15 ScrollView transcript, native scroll follower, 12-message initial batch, history pagination, and SelectableMarkdownView assistant rendering.
- Restore right-aligned user bubbles (18pt radius, 14/10pt text padding, 16.5pt scalable font, queued dashed outline), 60pt leading gutter, and selectable multiline text.
- Strip user attachment metadata from visible text; locate the closing tag after the opening tag.
- Restore assistant identity using the existing AssistantSoulName and the official sparkles styling.
- Restore system/compact divider presentation and compacted-history dimming.
- Use an iOS 15 native adaptive tile grid for persisted/queued message attachments; keep iOS 16+ FlowLayout. No copied post-build70 layout implementation.
- Run check-build70-chat-style.sh through the existing navigation-check CI step.

## Validation

Source guards and shell syntax checks are not Swift compilation or runtime tests.
A full Xcode CI build is required. The following remain device acceptance checks even after CI succeeds:

1. Open an existing conversation, return to the list, and re-enter it repeatedly.
2. Verify short/long user messages, text selection, dark mode, and font changes.
3. Verify assistant Markdown selection/copy and minis:// file links.
4. Verify multiple image/file attachments and queued attachment previews on narrow screens and rotation.
5. Verify streaming follow, manually reading older messages, and loading earlier history.
6. Verify system/compact divider wrapping and keyboard/composer bottom clearance.

The previously observed EXC_BAD_ACCESS in a later build is NOT established as fixed by source guards or a successful build. Do not claim runtime stability without testing the new IPA.
