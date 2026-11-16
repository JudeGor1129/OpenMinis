import Foundation

/// Small, auditable bundled skills that ship with Minis.
enum BundledSkillCatalog {
    /// Bumped when `ictrlContent` changes so an already-installed bundled
    /// copy is refreshed on the next launch. A user-imported skill with the
    /// same id is never overwritten.
    static let ictrlVersion = "2.0.0"

    static let ictrlContent = #"""
---
name: ictrl-phone-control
version: 2.0.0
description: Control this iPhone through the local iCTRL rootless daemon with the ictrl_call tool. Use when the user asks to read the screen, capture a screenshot, or inspect the device through iCTRL.
---

# iCTRL phone control

`ictrl_call` talks to the iCTRL daemon on the same device (default
`127.0.0.1:8200`) over an encrypted envelope. It is an in-app client: nothing
is downloaded, no shell is opened, and the session key stays inside the app
container.

Use it only on a device the user owns or is authorized to automate.

## Setup

1. The daemon must be installed and running. Check `device_info` first — that
   is the cheapest call and it fails clearly when the daemon is absent.
2. If the reply says you are not paired, call `action=pair` **once**. The
   device shows an approval prompt; the user must tap it. Pairing has a 15 s
   cooldown, so do not loop: report the prompt and wait for the user.
3. After pairing, `action=call` with `method` and `params_json` works until the
   token expires (30 days) or the user unpairs.

## Safe workflow

1. `device_info` — confirm the daemon answers and which backend it reports.
2. `screenshot` — the image is written to the app's attachments directory and
   the reply carries `saved_path`, `bytes` and the dimensions. Base64 pixels
   are never returned to the model, so do not ask for them.
3. Read the returned JSON before acting on it. An unknown method returns an
   error from the daemon, not a silent success.
4. Stop before irreversible actions (purchases, deletion, sending messages,
   account changes) unless the user explicitly confirms.

## What the shipped daemon actually implements

This matters more than the method list: the installed rootless daemon is the
read-only stage-1 build. It answers `device_info` and `screenshot`. Anything
else — `page_source`, `find_element`, `tap`, `type`, `swipe`, `launch_app` —
is only available if the daemon on the device implements it. If a call returns
an unsupported-method error, say so plainly and stop; do not retry with
invented parameters and do not claim the action happened.

## Rules

- Loopback or a private LAN address only. A public host is refused before any
  network traffic is made.
- Never ask the user for the pairing token, and never print it.
- Do not retry a refused pairing in a tight loop; the daemon rate-limits and
  every attempt needs a fresh on-device approval.
- Coordinates and taps are not a substitute for the user's own confirmation on
  destructive screens.
"""#
}
