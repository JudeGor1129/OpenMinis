---
name: ictrl-native-stage1
version: 0.1.0
---
# Read-only native bridge
Only `device_info` and `screenshot` exist. No XCTest/DDI/Lockdown/VPN required.
Endpoint: 127.0.0.1:8200. Pair once via matching ictrl CLI; confirm fingerprint and Allow on this device.
All RPC requires encrypted iCTRL envelope v1. Read device_info first.
Use screenshot {"format":"jpeg","scale":1,"quality":0.6}. Locked/unknown lock state refuses capture.
No tap, typing, accessibility tree, video, remote access, arbitrary shell or filesystem APIs.
This experimental build needs on-device cross-app screenshot verification. Never claim success solely from HTTP 200.
