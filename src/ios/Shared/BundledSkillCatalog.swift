import Foundation

/// Small, auditable bundled skills that ship with Minis.
enum BundledSkillCatalog {
    static let ictrlVersion = "1.0.0"

    static let ictrlContent = #"""
---
name: ictrl-phone-control
version: 1.0.0
description: Control a paired iPhone through the local iCTRL runner. Use when the user asks to inspect or operate another iOS app, read the current screen, tap, type, swipe, launch an app, or capture a screenshot through iCTRL.
---

# iCTRL phone control

Use iCTRL only on a device the user owns or is authorized to automate. iCTRL is a separate XCUITest runner; Minis is only its client.

## Setup

The runner must already be running. On the phone, the default endpoint is `127.0.0.1:8200`.

Install the matching client from the runner once:

```sh
C="$HOME/.ictrl/bin"
mkdir -p "$C"
wget -qO "$C/ictrl" http://127.0.0.1:8200/skill/clients/cli
wget -qO "$C/ictrl.sh" http://127.0.0.1:8200/skill/clients/cli.sh
chmod +x "$C/ictrl"
```

Pair once, only after the user expects the approval prompt:

```sh
sh "$HOME/.ictrl/bin/ictrl.sh" --host 127.0.0.1:8200 pair --name Minis
```

The user must approve pairing on the iCTRL runner. Never bypass pairing or retry a real 401 repeatedly.

## Safe workflow

1. Call `device_info` first.
2. Read the current screen with `page_source` using `visible_only:true` and a bounded child count.
3. Find controls by label with `find_element`; act with the returned `ref`.
4. Re-read after navigation or when the screen changes.
5. Use coordinate actions only when the accessibility tree cannot identify the target.
6. Stop before irreversible actions such as purchases, deletion, sending messages, or account changes unless the user explicitly confirms.

Examples:

```sh
I="sh $HOME/.ictrl/bin/ictrl.sh"
$I --host 127.0.0.1:8200 call device_info
$I --host 127.0.0.1:8200 call page_source '{"visible_only":true,"max_children":50}'
$I --host 127.0.0.1:8200 call resolve_app '{"text":"Settings|设置"}'
$I --host 127.0.0.1:8200 call launch_app '{"bundle_id":"com.apple.Preferences"}'
$I --host 127.0.0.1:8200 call find_element '{"element_id":"General"}'
$I --host 127.0.0.1:8200 call screenshot '{"format":"jpeg"}'
```

Useful methods include `device_info`, `page_source`, `screen_text`, `find_element`, `tap`, `type`, `clear_text`, `swipe`, `drag`, `page`, `scroll`, `launch_app`, `activate_app`, `terminate_app`, `open_url`, `screenshot`, `logs`, and `reset`. Read `/schema` or call the runner's `skill` endpoint when method parameters are unclear.

Do not start XCTest, mount a Developer Disk Image, modify pairing files, or expose the runner to the LAN unless the user explicitly asks. Remote access is off by default; if a LAN endpoint is used, verify it belongs to the user's device.
"""#
}
