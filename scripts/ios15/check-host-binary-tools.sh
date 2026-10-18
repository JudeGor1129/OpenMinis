#!/usr/bin/env bash
# [T-host-macho-tool] Source-level guard for the first-party Mach-O reader.
#
# The three checks that matter here are the ones that FAIL SILENTLY: a wrong
# magic constant, a wrong cputype constant, or a byte-swapped UUID all produce
# plausible-looking output rather than an error. Each was hit during
# development against real binaries, so each gets a guard.
set -euo pipefail
cd "$(dirname "$0")/../.."

impl=src/ios/Agent/Chat/AIChatViewModel+HostBinaryTools.swift
defs=src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
dispatch=src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
pbx=src/ios/Minis.xcodeproj/project.pbxproj

[ -f "$impl" ] || { echo "FAIL: missing $impl"; exit 1; }

echo "== tool registration =="
grep -q 'name: "host_macho_info"' "$defs" || { echo "FAIL: host_macho_info not defined"; exit 1; }
grep -q 'case "host_macho_info":' "$dispatch" || { echo "FAIL: host_macho_info not dispatched"; exit 1; }
grep -q 'func executeHostMachOInfo(' "$impl" || { echo "FAIL: missing executeHostMachOInfo"; exit 1; }
echo "  host_macho_info defined, dispatched and implemented"

echo "== fat magic compared in the accessor's byte order =="
# The fat header is big-endian; read through a LE u32 accessor the constant
# must be byte-swapped. 0xcafebabe here would silently skip every universal binary.
grep -q '0xbeba_feca' "$impl" || { echo "FAIL: 32-bit fat magic missing byte-swapped constant"; exit 1; }
grep -q '0xbfba_feca' "$impl" || { echo "FAIL: 64-bit fat magic missing byte-swapped constant"; exit 1; }
# Use the big-endian accessors for the fat arch list.
grep -q 'head.be32(at: 4)' "$impl" || { echo "FAIL: fat nfat_arch not read big-endian"; exit 1; }
echo "  fat magic uses byte-swapped constants; arch list read through be32/be64"

echo "== arm64 cputype includes the 64-bit ABI bit =="
grep -q 'cputypeArm64: UInt32 = 0x0100_000c' "$impl" || {
    echo "FAIL: cputypeArm64 must be 0x0100000c (CPU_ARCH_ABI64|CPU_TYPE_ARM), not 0x0c"; exit 1; }
echo "  cputypeArm64 = 0x0100000c"

echo "== arm64e distinguished by masking capability bits =="
grep -q 'subtypeBaseMask: UInt32 = 0x00ff_ffff' "$impl" || { echo "FAIL: subtype mask missing"; exit 1; }
grep -q 'cpuSubtype & MachO.subtypeBaseMask' "$impl" || { echo "FAIL: subtype not masked before comparison"; exit 1; }
grep -q '"arm64e"' "$impl" || { echo "FAIL: arm64e not reported"; exit 1; }
echo "  cpusubtype masked; base 2 reported as arm64e"

echo "== UUID read in file order, not as little-endian words =="
grep -q 'case MachO.lcUuid:' "$impl" || { echo "FAIL: lcUuid case missing"; exit 1; }
grep -q 'cmds.byte(at: cursor + 8 + i)' "$impl" || {
    echo "FAIL: LC_UUID must be read byte-by-byte; reading it as u32 words byte-swaps it"; exit 1; }
echo "  LC_UUID formatted from raw bytes"

echo "== encryption state reported =="
grep -q 'lcEncryptionInfo64' "$impl" || { echo "FAIL: no LC_ENCRYPTION_INFO_64 handling"; exit 1; }
grep -q 'encrypted: YES' "$impl" || { echo "FAIL: encrypted binaries not flagged"; exit 1; }
grep -q 'frida-ios-dump' "$impl" || { echo "FAIL: no dump guidance for encrypted binaries"; exit 1; }
echo "  cryptid surface + dump guidance present"

echo "== bounds-checked reads =="
for fn in 'func u32(at offset: Int)' 'func u64(at offset: Int)' 'func be32(at offset: Int)' \
          'func be64(at offset: Int)' 'func cString(at offset: Int' 'func byte(at offset: Int)'; do
    grep -q "$fn" "$impl" || { echo "FAIL: missing bounds-checked accessor: $fn"; exit 1; }
done
grep -q 'maxLoadCommands' "$impl" || { echo "FAIL: load command count unbounded"; exit 1; }
grep -q 'maxStringLength' "$impl" || { echo "FAIL: string reads unbounded"; exit 1; }
grep -q 'maxLoadCommandBytes' "$impl" || { echo "FAIL: load command region unbounded"; exit 1; }
echo "  six bounds-checked accessors plus load-command/string caps"

echo "== read-only, off the main actor =="
grep -q 'FileHandle(forReadingFrom:' "$impl" || { echo "FAIL: file not opened for reading"; exit 1; }
if grep -nE '^\s*(try )?Data\(contentsOf|\.write\(to:|FileManager.default.removeItem' "$impl" | grep -q .; then
    echo "FAIL: binary inspection must not read whole files or write/delete anything"; exit 1
fi
grep -q 'Task.detached(priority: .userInitiated)' "$impl" || { echo "FAIL: parsing not detached"; exit 1; }
echo "  read-only file handle, no writes, parsing detached"

echo "== uses the read path guard (not the write gate) =="
grep -q 'resolveHostToolPath(rawPath, root: root)' "$impl" || { echo "FAIL: should use the read resolver"; exit 1; }
if grep -q 'resolveHostWriteTarget' "$impl"; then
    echo "FAIL: inspection must not use the write resolver"; exit 1
fi
echo "  read guard only; credential stores stay refused via the shared resolver"

echo "== Xcode registration =="
grep -q 'E5MB0001 /\* AIChatViewModel+HostBinaryTools.swift in Sources \*/,' "$pbx" || { echo "FAIL: no Sources membership"; exit 1; }
grep -q 'E5MB0002 /\* AIChatViewModel+HostBinaryTools.swift \*/' "$pbx" || { echo "FAIL: no file reference"; exit 1; }
echo "  build file, file reference and Sources membership present"

echo "PASS: host_macho_info parses Mach-O headers with correct byte order and bounds."
echo "NOTE: not proof of Swift compilation. Parser output was cross-checked against"
echo "      /var/jb/usr/sbin/frida-server (fat arm64+arm64e) and"
echo "      /Applications/AAUIViewService.app/AAUIViewService (thin arm64e) in Python."
