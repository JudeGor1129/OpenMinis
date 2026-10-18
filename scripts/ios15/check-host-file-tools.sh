#!/usr/bin/env bash
# [T-host-file-tools] Source-level guards for the iOS-side read-only file tools.
#
# These checks cannot prove the Swift compiles. They prove the three things that
# silently break a tool: it is not registered in the Xcode project, it is not
# advertised in makeAgentTools(), or it is advertised but has no dispatch case.
# A tool that is listed but undispatched fails at runtime with "unknown tool",
# which is exactly the failure this catches before a build is spent.
set -euo pipefail

cd "$(dirname "$0")/../.."

impl=src/ios/Agent/Chat/AIChatViewModel+HostFileTools.swift
defs=src/ios/Agent/Chat/AIChatViewModel+ToolDefinitions.swift
dispatch=src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift
pbx=src/ios/Minis.xcodeproj/project.pbxproj

for f in "$impl" "$defs" "$dispatch" "$pbx"; do
    [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

tools=(host_list_files host_read_file host_search_files host_search_text host_file_info)

echo "== tool registration =="
for t in "${tools[@]}"; do
    grep -q "name: \"$t\"" "$defs" || { echo "FAIL: $t not defined in makeAgentTools()"; exit 1; }
    grep -q "case \"$t\":" "$dispatch" || { echo "FAIL: $t has no dispatch case"; exit 1; }
    echo "  $t: defined + dispatched"
done

echo "== implementation entry points =="
grep -q 'func resolveHostToolPath(' "$impl"
grep -q 'func executeHostListFiles(' "$impl"
grep -q 'func executeHostReadFile(' "$impl"
grep -q 'func executeHostSearchFiles(' "$impl"
grep -q 'func executeHostSearchText(' "$impl"
grep -q 'func executeHostFileInfo(' "$impl"
echo "  all six entry points present"

echo "== dual-root support =="
grep -q 'case "ish":' "$impl"
grep -q 'case "ios", "":' "$impl"
grep -q 'resolveHostPath(trimmed)' "$impl"
# [T-host-symlink-follow] iSH serves /var/minis/** through symlinks into a
# shared AppGroup container; without resolution, listing failed with
# "could not open file skills" while the target was readable.
grep -q 'resolvingSymlinksInPath()' "$impl"
grep -q 'symlink-resolved' "$impl"
grep -q 'l  \\(child.lastPathComponent) -> ' "$impl"
echo "  ios and ish roots both resolved; symlinks followed and labelled"

echo "== credential stores refused =="
grep -q '/var/mobile/Library/Keychains' "$impl"
grep -q 'hostDeniedPathPrefixes' "$impl"
grep -q 'is a credential store' "$impl"
echo "  keychain prefixes denied before any read or write"

echo "== bounded traversal and output =="
grep -q '80_000' "$impl"
grep -q 'Self.kMaxToolResultChars' "$impl"
grep -q 'max_scanned' "$impl"
grep -q 'max_files' "$impl"
grep -q '2 \* 1024 \* 1024' "$impl"
echo "  per-file cap, scan caps and result clamp present"

echo "== off-main-actor IO =="
count=$(grep -c 'Task.detached(priority: .userInitiated)' "$impl")
[ "$count" -eq 5 ] || { echo "FAIL: expected 5 detached IO blocks, found $count"; exit 1; }
echo "  all 5 tools hand filesystem work to a detached task"

echo "== Xcode project registration =="
grep -q 'E5HF0001 /\* AIChatViewModel+HostFileTools.swift in Sources \*/' "$pbx"
grep -q 'E5HF0002 /\* AIChatViewModel+HostFileTools.swift \*/' "$pbx"
sources=$(grep -c 'E5HF0001 /\* AIChatViewModel+HostFileTools.swift in Sources \*/,' "$pbx")
[ "$sources" -eq 1 ] || { echo "FAIL: file not in the Sources build phase exactly once (found $sources)"; exit 1; }
echo "  build file, file reference and Sources membership present"

echo "PASS: host read-only file tools are defined, dispatched, registered and bounded."

# ---- [T-host-write-tools] write slice ----
wimpl=src/ios/Agent/Chat/AIChatViewModel+HostWriteTools.swift
wtools=(host_write_file host_append_file host_edit_file host_delete_file host_move_file host_copy_file)
[ -f "$wimpl" ] || { echo "FAIL: missing $wimpl"; exit 1; }

echo "== write tool registration =="
for t in "${wtools[@]}"; do
    grep -q "name: \"$t\"" "$defs" || { echo "FAIL: $t not defined in makeAgentTools()"; exit 1; }
    grep -q "case \"$t\":" "$dispatch" || { echo "FAIL: $t has no dispatch case"; exit 1; }
    echo "  $t: defined + dispatched"
done

echo "== write implementation entry points =="
for fn in executeHostWriteFile executeHostAppendFile executeHostEditFile \
          executeHostDeleteFile executeHostMoveFile executeHostCopyFile; do
    grep -q "func $fn(" "$wimpl" || { echo "FAIL: missing $fn"; exit 1; }
done
echo "  all six write entry points present"

echo "== write safety gates =="
grep -q 'hostWriteForbiddenPathPrefixes' "$wimpl"
grep -q 'hostWriteSystemPathPrefixes' "$wimpl"
grep -q 'allow_system=true' "$wimpl"
grep -q 'can never be written by a tool, even with allow_system' "$wimpl"
# Credential stores must stay refused even when allow_system is set: the
# forbid list is consulted BEFORE the allowSystem early-return.
grep -A 12 'hostWriteDenial(for path: String' "$wimpl" | grep -q 'guard !allowSystem else'
echo "  credential stores unconditionally refused; system area needs allow_system=true"

echo "== destructive defaults =="
grep -q 'recursive=true to delete it' "$wimpl"
grep -q 'is a container root' "$wimpl"
grep -q 'refusing to guess which one' "$wimpl"
echo "  directory delete needs recursive=true; container roots guarded; edit refuses ambiguous match"

echo "== write IO off the main actor =="
wcount=$(grep -c 'Task.detached(priority: .userInitiated)' "$wimpl")
[ "$wcount" -eq 5 ] || { echo "FAIL: expected 5 detached IO blocks in the write slice, found $wcount"; exit 1; }
echo "  5 detached IO blocks (write, append, edit, delete, transfer)"

echo "== write slice Xcode registration =="
grep -q 'E5HW0001 /\* AIChatViewModel+HostWriteTools.swift in Sources \*/,' "$pbx"
grep -q 'E5HW0002 /\* AIChatViewModel+HostWriteTools.swift \*/' "$pbx"
echo "  build file, file reference and Sources membership present"

echo "PASS: host write tools are defined, dispatched, gated and registered."

printf 'NOTE: not proof of Swift compilation, iOS permission grants or real device reachability.\n'
