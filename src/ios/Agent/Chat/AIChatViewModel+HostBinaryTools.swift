import Foundation

// MARK: - Host Mach-O inspection tool  [T-host-macho-tool]
//
// Why this is hand-written rather than shelling out: the analysis done on this
// device has no `otool`, `nm`, `lipo`, `jtool2` or `class-dump` — only
// `hexdump` and `ldid` exist in the jailbreak bootstrap. So a first-party
// reader is the only way to answer "what architectures does this dylib
// contain", "is this App Store binary still encrypted", "which dylibs does it
// link", which are the first questions in every reverse-engineering session.
//
// READ-ONLY by construction: the file is opened for reading, only header and
// load-command regions are read, and nothing is ever executed or written. It
// therefore uses the READ path guard, not the write gate — but the credential
// stores stay refused because that check lives in the shared resolver.
//
// Parsing is bounded at every level (load command count, string length,
// per-command payload, listed dylibs/sections, output size) because a malformed
// or hostile file must not be able to stall the UI or exhaust memory.

extension AIChatViewModel {

    // MARK: - Mach-O constants

    private enum MachO {
        static let magic32: UInt32 = 0xfeed_face
        static let magic64: UInt32 = 0xfeed_facf
        // The fat header is defined BIG-ENDIAN regardless of host byte order,
        // so when it is read through the little-endian `u32` accessor the value
        // must be compared against the BYTE-SWAPPED constant. On-disk bytes
        // CA FE BA BE read as a LE u32 give 0xBEB AFECA — comparing against
        // `0xcafebabe` here silently misses every universal binary.
        static let fatMagic: UInt32 = 0xbeba_feca     // bytes CA FE BA BE (32-bit fat)
        static let fatMagic64: UInt32 = 0xbfba_feca   // bytes CA FE BA BF (64-bit fat)

        // Load commands we surface.
        static let lcSegment64: UInt32 = 0x19
        static let lcUuid: UInt32 = 0x1b
        static let lcIdDylib: UInt32 = 0x0d
        static let lcLoadDylib: UInt32 = 0x0c
        static let lcLoadWeakDylib: UInt32 = 0x8000_0018
        static let lcReexportDylib: UInt32 = 0x8000_001f
        static let lcRpath: UInt32 = 0x8000_001c
        static let lcMain: UInt32 = 0x8000_0028
        static let lcCodeSignature: UInt32 = 0x1d
        static let lcEncryptionInfo64: UInt32 = 0x2c
        static let lcBuildVersion: UInt32 = 0x32
        static let lcVersionMinIPhoneOS: UInt32 = 0x25
        static let lcVersionMinMacOSX: UInt32 = 0x24
        static let lcDylinker: UInt32 = 0x0e

        static let cpuArch64: UInt32 = 0x0100_0000
        // Mach-O cputype for 64-bit ARM is CPU_ARCH_ABI64 (0x01000000) OR'd
        // with CPU_TYPE_ARM (12) — NOT plain 12. Comparing against 0x0c never
        // matches a real arm64 binary and every architecture name silently
        // degrades to "cputype 0x100000c". Verified against frida-server and
        // AAUIViewService (both 0x0100000c).
        static let cputypeArm64: UInt32 = 0x0100_000c

        // Capability bits live above the base subtype. Masking them off is
        // what distinguishes arm64e (subtype 2) from arm64 with PAC bits set —
        // the same masking the build diagnostics depend on.
        static let subtypeBaseMask: UInt32 = 0x00ff_ffff

        static let maxLoadCommands = 4096
        static let maxLoadCommandBytes = 1 << 20      // 1 MiB of load commands
        static let maxStringLength = 512
        static let maxListedItems = 200
    }

    /// A byte window plus bounds-checked little-endian readers.
    ///
    /// Every accessor returns nil rather than trapping when the offset falls
    /// outside the window, so a truncated or deliberately malformed file
    /// degrades into "field unavailable" instead of crashing the app.
    struct MachOWindow {
        let bytes: [UInt8]

        var count: Int { bytes.count }

        /// Single byte, bounds-checked. Needed where byte ORDER matters —
        /// notably the UUID, which is stored and displayed in file order and
        /// must not be reinterpreted as little-endian words.
        func byte(at offset: Int) -> UInt8? {
            guard offset >= 0, offset < bytes.count else { return nil }
            return bytes[offset]
        }

        func u32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }

        func u64(at offset: Int) -> UInt64? {
            guard let lo = u32(at: offset), let hi = u32(at: offset + 4) else { return nil }
            return UInt64(lo) | (UInt64(hi) << 32)
        }

        /// Big-endian reader, needed only for the fat header and its arch list
        /// (the fat format is defined big-endian regardless of host order).
        func be32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return (UInt32(bytes[offset]) << 24)
                | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8)
                | UInt32(bytes[offset + 3])
        }

        func be64(at offset: Int) -> UInt64? {
            guard let hi = be32(at: offset), let lo = be32(at: offset + 4) else { return nil }
            return (UInt64(hi) << 32) | UInt64(lo)
        }

        /// NUL-terminated C string with a hard length cap.
        func cString(at offset: Int, limit: Int = MachO.maxStringLength) -> String? {
            guard offset >= 0, offset < bytes.count else { return nil }
            var out: [UInt8] = []
            var i = offset
            while i < bytes.count, i - offset < limit {
                let b = bytes[i]
                if b == 0 { return String(decoding: out, as: UTF8.self) }
                out.append(b)
                i += 1
            }
            return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
        }
    }

    /// Human-readable architecture for a cputype/subtype pair.
    nonisolated static func machOArchitecture(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        let base = cpuSubtype & MachO.subtypeBaseMask
        if cpuType == MachO.cputypeArm64 {
            switch base {
            case 2: return "arm64e"
            case 1: return "arm64 (v8)"
            case 0: return "arm64"
            default: return "arm64 (subtype \(base))"
            }
        }
        if cpuType == 7 { return "i386" }
        if cpuType == 0x0100_0007 { return "x86_64" }
        return "cputype 0x\(String(cpuType, radix: 16))"
    }

    /// One architecture slice, either from a fat header or the thin file itself.
    struct MachOSlice {
        let arch: String
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let offset: Int
        let size: Int
    }

    /// Parse the fat header, or describe the file as a single thin slice.
    nonisolated static func machOSlices(head: MachOWindow, fileSize: Int) -> (slices: [MachOSlice], isFat: Bool)? {
        guard let magic = head.u32(at: 0) else { return nil }
        if magic == MachO.fatMagic || magic == MachO.fatMagic64 {
            let is64 = magic == MachO.fatMagic64
            guard let rawCount = head.be32(at: 4) else { return nil }
            let count = min(Int(rawCount), 32)
            var out: [MachOSlice] = []
            let entrySize = is64 ? 32 : 20
            for i in 0..<count {
                let base = 8 + i * entrySize
                guard let cpu = head.be32(at: base),
                      let sub = head.be32(at: base + 4),
                      let off = is64 ? head.be64(at: base + 8) : UInt64(head.be32(at: base + 8) ?? 0),
                      let sz = is64 ? head.be64(at: base + 16) : UInt64(head.be32(at: base + 12) ?? 0)
                else { break }
                out.append(MachOSlice(arch: machOArchitecture(cpuType: cpu, cpuSubtype: sub),
                                      cpuType: cpu, cpuSubtype: sub,
                                      offset: Int(off), size: Int(sz)))
            }
            return (out, true)
        }
        return (nil, false)
    }

    /// Analyse one thin Mach-O image located at `offset` inside `url`.
    ///
    /// Reads only the header and load-command region, seeking directly to
    /// `offset`, so a fat binary's later slice does not require reading the
    /// whole file into memory.
    nonisolated static func machOImageDescription(url: URL, offset: Int, archHint: String?) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return ["  (cannot open file)"]
        }
        defer { try? handle.close() }

        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let headData = try? handle.read(upToCount: 64 * 1024),
              headData.count >= 32
        else { return ["  (cannot read header at this offset)"] }

        let head = MachOWindow(bytes: [UInt8](headData))
        guard let magic = head.u32(at: 0) else { return ["  (bad magic)"] }
        let is64: Bool
        switch magic {
        case MachO.magic64: is64 = true
        case MachO.magic32: is64 = false
        default:
            return ["  (not a Mach-O image; magic 0x\(String(magic, radix: 16)))"]
        }

        var lines: [String] = []
        guard let cpu = head.u32(at: 4), let sub = head.u32(at: 8) else { return ["  (truncated header)"] }
        let arch = archHint ?? machOArchitecture(cpuType: cpu, cpuSubtype: sub)
        lines.append("  arch:      \(arch)\(is64 ? " (64-bit)" : " (32-bit)")")

        guard let fileType = head.u32(at: 12),
              let ncmds = head.u32(at: 16),
              let sizeofcmds = head.u32(at: 20)
        else { return lines + ["  (truncated header)"] }

        let fileTypes: [UInt32: String] = [
            1: "object", 2: "executable", 3: "fixed VM library", 4: "core",
            5: "preloaded executable", 6: "dynamic library", 7: "dynamic linker",
            8: "bundle", 9: "dynamic library stub", 10: "dSYM companion", 11: "kext bundle",
        ]
        lines.append("  filetype:  \(fileTypes[fileType] ?? "type \(fileType)")")

        // Load commands start right after the header: 32 bytes for 64-bit.
        let cmdStart = is64 ? 32 : 28
        var cmdBytes = Int(sizeofcmds)
        var cmds = head
        if Int(sizeofcmds) > head.count - cmdStart {
            // Load commands did not fit in the head read — pull the region we
            // actually need, capped, rather than the whole file.
            cmdBytes = min(Int(sizeofcmds), MachO.maxLoadCommandBytes)
            if (try? handle.seek(toOffset: UInt64(offset + cmdStart))) != nil,
               let region = try? handle.read(upToCount: cmdBytes) {
                cmds = MachOWindow(bytes: [UInt8](region))
            } else {
                return lines + ["  (cannot read load commands)"]
            }
        }

        var segments: [String] = []
        var dylibs: [String] = []
        var rpaths: [String] = []
        var uuid: String?
        var entry: UInt64?
        var cryptid: UInt32?
        var cryptoff: UInt32?
        var cryptsize: UInt32?
        var minOS: String?
        var sdk: String?
        var hasCodeSignature = false
        var dylinker: String?
        var sectionCount = 0

        var cursor = 0
        var consumed = 0
        var index = 0
        while index < Int(ncmds), index < MachO.maxLoadCommands, consumed < cmdBytes {
            guard let rawCmd = cmds.u32(at: cursor), let rawSize = cmds.u32(at: cursor + 4) else { break }
            let size = Int(rawSize)
            // A load command smaller than its own header, or one that runs past
            // the region we read, means the file is malformed — stop cleanly.
            guard size >= 8, cursor + size <= cmds.count else { break }

            switch rawCmd {
            case MachO.lcSegment64:
                var name = cmds.cString(at: cursor + 8) ?? "?"
                // 16-byte segment names are not always NUL-terminated.
                if name.count > 16 { name = String(name.prefix(16)) }
                let vmaddr = cmds.u64(at: cursor + 24) ?? 0
                let vmsize = cmds.u64(at: cursor + 32) ?? 0
                let fileoff = cmds.u64(at: cursor + 40) ?? 0
                let filesize = cmds.u64(at: cursor + 48) ?? 0
                guard let nsects = cmds.u32(at: cursor + 64) else { break }
                sectionCount += Int(nsects)
                if segments.count < MachO.maxListedItems {
                    // Padded in Swift rather than via a `%-16@` format string:
                    // field width with %@ depends on Foundation's formatter and
                    // is easy to get subtly wrong across locales.
                    let padded = name.count >= 16 ? name : name + String(repeating: " ", count: 16 - name.count)
                    segments.append("    \(padded) vmaddr 0x\(String(vmaddr, radix: 16))"
                                    + " vmsize 0x\(String(vmsize, radix: 16))"
                                    + " fileoff 0x\(String(fileoff, radix: 16))"
                                    + " filesize 0x\(String(filesize, radix: 16))"
                                    + " sections \(nsects)")
                }
            case MachO.lcUuid:
                // LC_UUID is 16 raw bytes in file order, NOT four little-endian
                // words. Rendering it through `u32` byte-swaps every group and
                // produces a UUID that never matches `dwarfdump`/`otool` output
                // (verified: it yielded 2A057467-… for a binary whose real UUID
                // is 6774052A-…). Read bytes and format them directly.
                let hex = (0..<16).map { i -> String in
                    guard let b = cmds.byte(at: cursor + 8 + i) else { return "" }
                    return String(format: "%02X", b)
                }
                if hex.allSatisfy({ $0.count == 2 }) {
                    uuid = "\(hex[0])\(hex[1])\(hex[2])\(hex[3])-\(hex[4])\(hex[5])"
                        + "-\(hex[6])\(hex[7])-\(hex[8])\(hex[9])"
                        + "-\(hex[10])\(hex[11])\(hex[12])\(hex[13])\(hex[14])\(hex[15])"
                }
            case MachO.lcIdDylib, MachO.lcLoadDylib, MachO.lcLoadWeakDylib, MachO.lcReexportDylib:
                // name offset is relative to the command start.
                if let nameOff = cmds.u32(at: cursor + 8),
                   let name = cmds.cString(at: cursor + Int(nameOff)) {
                    let kind: String
                    switch rawCmd {
                    case MachO.lcIdDylib: kind = "ID"
                    case MachO.lcLoadWeakDylib: kind = "weak"
                    case MachO.lcReexportDylib: kind = "reexport"
                    default: kind = "load"
                    }
                    if dylibs.count < MachO.maxListedItems {
                        dylibs.append("    [\(kind)] \(name)")
                    }
                }
            case MachO.lcDylinker:
                if let nameOff = cmds.u32(at: cursor + 8) {
                    dylinker = cmds.cString(at: cursor + Int(nameOff))
                }
            case MachO.lcRpath:
                if let nameOff = cmds.u32(at: cursor + 8),
                   let path = cmds.cString(at: cursor + Int(nameOff)) {
                    rpaths.append(path)
                }
            case MachO.lcMain:
                entry = cmds.u64(at: cursor + 8)
            case MachO.lcCodeSignature:
                hasCodeSignature = true
                if let sigOff = cmds.u32(at: cursor + 8), let sigSize = cmds.u32(at: cursor + 12) {
                    lines.append("  signature: present (fileoff 0x\(String(sigOff, radix: 16)), size \(sigSize))")
                }
            case MachO.lcEncryptionInfo64:
                cryptoff = cmds.u32(at: cursor + 8)
                cryptsize = cmds.u32(at: cursor + 12)
                cryptid = cmds.u32(at: cursor + 16)
            case MachO.lcBuildVersion:
                if let platform = cmds.u32(at: cursor + 8) {
                    let platforms: [UInt32: String] = [1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 6: "macCatalyst"]
                    let minHex = cmds.u32(at: cursor + 12) ?? 0
                    let sdkHex = cmds.u32(at: cursor + 16) ?? 0
                    minOS = "\(platforms[platform] ?? "platform \(platform)") \(machOVersionString(minHex))"
                    sdk = machOVersionString(sdkHex)
                }
            case MachO.lcVersionMinIPhoneOS, MachO.lcVersionMinMacOSX:
                let minHex = cmds.u32(at: cursor + 8) ?? 0
                let sdkHex = cmds.u32(at: cursor + 12) ?? 0
                minOS = "\(rawCmd == MachO.lcVersionMinIPhoneOS ? "iOS" : "macOS") \(machOVersionString(minHex))"
                sdk = machOVersionString(sdkHex)
            default:
                break
            }

            cursor += size
            consumed += size
            index += 1
        }

        let parsed = index
        lines.append("  commands:  \(ncmds) load commands (\(parsed) parsed, \(sizeofcmds) bytes)")
        lines.append("  sections:  \(sectionCount)")
        if let uuid { lines.append("  uuid:      \(uuid)") }
        if let minOS { lines.append("  minimum:   \(minOS)\(sdk.map { ", SDK \($0)" } ?? "")") }
        if let dylinker { lines.append("  linker:    \(dylinker)") }
        if let entry {
            lines.append("  entry:     0x\(String(entry, radix: 16)) (LC_MAIN offset)")
        } else {
            lines.append("  entry:     none (LC_MAIN absent — not a main executable)")
        }
        lines.append("  codesig:   \(hasCodeSignature ? "LC_CODE_SIGNATURE present" : "no LC_CODE_SIGNATURE")")

        // Encryption state is the single most consequential fact when picking a
        // target: cryptid 1 means the App Store binary is still encrypted and
        // static analysis will show garbage for the code sections.
        if let cryptid {
            if cryptid == 0 {
                lines.append("  encrypted: no (LC_ENCRYPTION_INFO_64 cryptid 0 — decrypted)")
            } else {
                lines.append("  encrypted: YES (cryptid \(cryptid), cryptoff 0x\(String(cryptoff ?? 0, radix: 16)), cryptsize \(cryptsize ?? 0))"
                             + " — dump with frida-ios-dump/Clutch before static analysis")
            }
        } else {
            lines.append("  encrypted: no LC_ENCRYPTION_INFO_64 (typical for dylibs and frameworks)")
        }

        if !segments.isEmpty {
            lines.append("  segments:")
            lines.append(contentsOf: segments)
        }
        if !dylibs.isEmpty {
            lines.append("  linked libraries (\(dylibs.count)\(dylibs.count >= MachO.maxListedItems ? "+" : "")):")
            lines.append(contentsOf: dylibs)
        }
        if !rpaths.isEmpty {
            lines.append("  rpaths:")
            lines.append(contentsOf: rpaths.prefix(20).map { "    \($0)" })
        }
        return lines
    }

    /// Packed 32-bit version (xxxx.yy.zz nibbles) as a readable string.
    nonisolated static func machOVersionString(_ packed: UInt32) -> String {
        let major = (packed >> 16) & 0xffff
        let minor = (packed >> 8) & 0xff
        let patch = packed & 0xff
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// Full analysis entry point for one path.
    nonisolated static func machOReport(url: URL) -> String {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return "Error: No such file (or it is a directory): \(url.path)"
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard let headHandle = try? FileHandle(forReadingFrom: url),
              let headData = try? headHandle.read(upToCount: 4096) else {
            return "Error: Cannot read \(url.path) — is it readable by the app?"
        }
        try? headHandle.close()

        let head = MachOWindow(bytes: [UInt8](headData))
        guard head.count >= 4 else {
            return "\(url.path) is \(size) bytes — too small to be a Mach-O file."
        }

        var lines = ["file: \(url.path)", "size: \(size) bytes (\(hostByteSize(size)))"]

        guard let (slices, isFat) = machOSlices(head: head, fileSize: size) else {
            return (lines + ["Not a Mach-O file (unrecognised magic bytes). "
                             + "If this is a .deb or .ipa, extract it first."]).joined(separator: "\n")
        }

        if isFat, let slices {
            lines.append("format: universal (fat) binary, \(slices.count) slice(s)")
            lines.append("")
            for (i, slice) in slices.enumerated() {
                lines.append("--- slice \(i + 1)/\(slices.count): \(slice.arch) ---")
                lines.append(String(format: "  cputype:   0x%08x  cpusubtype 0x%08x (subtype base %u)",
                                    slice.cpuType, slice.cpuSubtype, slice.cpuSubtype & MachO.subtypeBaseMask))
                lines.append(String(format: "  offset:    0x%x  size %d bytes (%@)",
                                    slice.offset, slice.size, hostByteSize(slice.size)))
                lines.append(contentsOf: machOImageDescription(url: url, offset: slice.offset, archHint: slice.arch))
                lines.append("")
            }
            // Unclamped here: `kMaxToolResultChars` is main-actor isolated, and
            // this function is nonisolated so it can run in a detached task.
            // The caller clamps.
            return lines.joined(separator: "\n")
        }

        lines.append("format: thin Mach-O (single architecture)")
        lines.append("")
        lines.append(contentsOf: machOImageDescription(url: url, offset: 0, archHint: nil))
        return lines.joined(separator: "\n")
    }

    // MARK: - host_macho_info

    func executeHostMachOInfo(from json: String) async -> FileToolResult {
        guard let dict = Self.hostArgs(json) else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        let root = (dict["root"] as? String) ?? "ios"
        guard let rawPath = dict["path"] as? String else {
            return FileToolResult(output: "Error: Missing required 'path' parameter.", success: false)
        }
        // Read path, so the read guard applies: credential stores stay refused.
        let resolution = resolveHostToolPath(rawPath, root: root)
        if let error = resolution.error {
            return FileToolResult(output: "Error: \(error)", success: false)
        }
        guard let url = resolution.url else {
            return FileToolResult(output: "Error: Unresolved path: \(rawPath)", success: false)
        }
        let report = await Task.detached(priority: .userInitiated) { () -> String in
            Self.machOReport(url: url)
        }.value
        let failed = report.hasPrefix("Error:") || report.contains("Not a Mach-O file")
        let clamped = Self.hostClamp(report, limit: Self.kMaxToolResultChars)
        return FileToolResult(output: clamped, success: !failed)
    }
}
