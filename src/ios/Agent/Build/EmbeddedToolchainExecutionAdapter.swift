import Foundation
import CryptoKit
import Darwin

/// Validation-only seam. No project root, shell command, raw argv or external
/// object is accepted. All files belong to one disposable, adapter-owned run.
struct EmbeddedAdapterCall: Sendable {
    let status: Int
    let stdout: String
    let stderr: String
}

protocol EmbeddedAdapterBridge: Sendable {
    func capability() -> [String: String]
    func residentBytes() -> UInt64
    func verifiedLibSystemStub() throws -> Data
    func verifiedObjCRuntimeStub() throws -> Data
    func compile(_ arguments: [String]) -> EmbeddedAdapterCall
    func link(_ arguments: [String]) -> EmbeddedAdapterCall
}

struct EmbeddedNativeAdapterBridge: EmbeddedAdapterBridge {
    static let libSystemSHA256 = "1ab02266a39491a8bd5a91ba36d5c8c8c6ac6efb92099e1091a1fd2370fc53e3"
    static let objcRuntimeSHA256 = "fac08e4c47fe8500b8cdf15205819c3f73166d71350a1fc0fe1741d01f6500da"
    func capability() -> [String: String] { OMToolchain.capabilityStatus() }

    func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    func verifiedLibSystemStub() throws -> Data {
        try verifiedRuntimeStub(at: "usr/lib/libSystem.B.tbd", expectedHash: Self.libSystemSHA256, description: "libSystem")
    }


    func verifiedObjCRuntimeStub() throws -> Data {
        try verifiedRuntimeStub(at: "usr/lib/libobjc.A.tbd", expectedHash: Self.objcRuntimeSHA256, description: "libobjc")
    }

    func compile(_ arguments: [String]) -> EmbeddedAdapterCall {
        var out: NSString?, err: NSString?
        let status = OMToolchain.runCC1(arguments, stdout: &out, stderr: &err)
        return EmbeddedAdapterCall(status: status.rawValue, stdout: out as String? ?? "", stderr: err as String? ?? "")
    }
    func link(_ arguments: [String]) -> EmbeddedAdapterCall {
        var out: NSString?, err: NSString?
        let status = OMToolchain.runLinker(arguments, stdout: &out, stderr: &err)
        return EmbeddedAdapterCall(status: status.rawValue, stdout: out as String? ?? "", stderr: err as String? ?? "")
    }

    private func verifiedRuntimeStub(at relativePath: String, expectedHash: String, description: String) throws -> Data {
        guard let sdk = capability()["sysroot"], sdk.hasSuffix("/iPhoneOS16.5.sdk") else {
            throw EmbeddedAdapterError.rejected("\(description) requires the pinned SDK16.5 runtime stub")
        }
        let path = URL(fileURLWithPath: sdk).appendingPathComponent(relativePath).path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw EmbeddedAdapterError.rejected("\(description) stub is missing or unsafe") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 1024, info.st_size <= 2 * 1024 * 1024 else {
            throw EmbeddedAdapterError.rejected("\(description) stub is not a bounded regular file")
        }
        let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count >= 1024, data.count <= 2 * 1024 * 1024,
              EmbeddedAdapterArtifact.digest(data) == expectedHash else {
            throw EmbeddedAdapterError.rejected("\(description) stub differs from the pinned SDK16.5 content")
        }
        return data
    }
}

final class EmbeddedAdapterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }

    /// Linearize cancellation against publication's rename. Cancellation before
    /// this critical section prevents publication; after it, the commit won.
    func commitIfNotCancelled<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !value else { throw CancellationError() }
        return try body()
    }
}

enum EmbeddedAdapterError: Error, LocalizedError, Sendable {
    case rejected(String)
    case poisoned(String)

    var errorDescription: String? {
        switch self {
        case .rejected(let reason): return "embedded adapter rejected: \(reason)"
        case .poisoned(let reason): return "embedded adapter poisoned: \(reason)"
        }
    }
}

struct EmbeddedAdapterArtifact: Codable, Sendable {
    let name: String
    let bytes: Int
    let sha256: String
    let architecture: String
    let filetype: UInt32

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Xcode's ld64 emits classic dyld info for arm64 and forces chained
    /// fixups for arm64e. The embedded driver must match that split.
    enum FixupPolicy: Sendable {
        case any
        case classic
        case xcodeCompatible
    }

    /// Inspect one thin target slice. Never rewrite headers to claim a target.
    /// Validate command/segment bounds; never load or execute generated code.
    static func inspect(_ data: Data, name: String, filetype: UInt32,
                        architecture: EmbeddedToolchainArchitecture = .arm64,
                        fixupPolicy: FixupPolicy = .any) throws -> Self {
        func invalid(_ rule: String = "structure", line: Int = #line) -> EmbeddedAdapterError {
            .poisoned("Mach-O output rejected: \(rule) (check_line=\(line))")
        }
        guard [UInt32(1), 2, 6].contains(filetype) else { throw invalid("unexpected_filetype=\(filetype)") }
        guard data.count >= 32, data.count <= 16 * 1024 * 1024 else { throw invalid("output_size_out_of_bounds") }
        func word(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
                UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        func wide(_ offset: Int) -> UInt64 { UInt64(word(offset)) | UInt64(word(offset + 4)) << 32 }
        guard word(0) == 0xfeedfacf, word(4) == 0x0100000c,
              architecture.accepts(subtype: word(8)), word(12) == filetype else {
            throw invalid("target_architecture_or_filetype_mismatch=\(architecture.rawValue)")
        }
        let count = Int(word(16)), length = Int(word(20))
        guard count > 0, count <= 4096, length >= count * 8, length <= data.count - 32 else { throw invalid() }
        var cursor = 32
        let end = cursor + length
        var hasSegment = false
        var dependencies: [String] = []
        var installNames: [String] = []
        var symbolCount: UInt64?
        var symbolRanges: [(UInt64, UInt64)] = []
        var optimizationHintRange: (UInt64, UInt64)?
        var linkeditFileRanges: [(UInt64, UInt64)] = []
        var occupiedObjectRanges: [(UInt64, UInt64)] = []
        var textFileRanges: [(UInt64, UInt64)] = []
        var encryptionRange: (UInt64, UInt64)?
        var hasClassicDyldInfo = false
        var hasChainedFixups = false
        // ld64 may emit LC_LINKER_OPTIMIZATION_HINT on both MH_OBJECT and dylib outputs.
        let objectCommands: Set<UInt32> = [0x19, 0x2, 0xb, 0x32, 0x25, 0x29, 0x2e]
        // Pinned ld64 also emits LC_ENCRYPTION_INFO_64 for iOS dylibs by
        // default, with cryptid=0. This is metadata, not encrypted content.
        // Admit only its bounded, unencrypted form; never bypass inspection.
        let dylibCommands = objectCommands.union([0xc, 0xd, 0x1b, 0x2e, 0x80000022, 0x26, 0x1d,
                                                  0x2a, 0x80000033, 0x80000034, 0x2c])
        // MH_EXECUTE (daemon/tool): system dylibs, a dyld stub, rpaths and LC_MAIN.
        let executableCommands = dylibCommands.union([0xe, 0x8000001c, 0x80000028])
        var hasMain = false
        func inFile(_ offset: UInt64, _ bytes: UInt64) -> Bool {
            offset <= UInt64(data.count) && bytes <= UInt64(data.count) - offset
        }
        for _ in 0..<count {
            guard cursor + 8 <= end else { throw invalid() }
            let command = word(cursor), size = Int(word(cursor + 4))
            if command == 0x2c && size != 24 { throw invalid("encryption_command_size_or_duplicate") }
            guard size >= 8, size % 8 == 0, size <= end - cursor else { throw invalid() }
            // Unknown/unsupported commands are rejected, not silently skipped.
            let admittedCommands = filetype == 1 ? objectCommands : (filetype == 2 ? executableCommands : dylibCommands)
            guard admittedCommands.contains(command) else {
                throw invalid("unsupported_load_command=0x\(String(command, radix: 16)),offset=\(cursor)")
            }
            if command == 0x19 {
                guard size >= 72 else { throw invalid() }
                let sectionCount = Int(word(cursor + 64))
                guard sectionCount <= (size - 72) / 80, size == 72 + sectionCount * 80 else { throw invalid() }
                let offset = wide(cursor + 40), bytes = wide(cursor + 48)
                guard inFile(offset, bytes) else { throw invalid() }
                let segmentName = data[(cursor + 8)..<(cursor + 24)]
                if segmentName.elementsEqual(Array("__TEXT".utf8) + Array(repeating: UInt8(0), count: 10)) {
                    textFileRanges.append((offset, bytes))
                } else if segmentName.elementsEqual(Array("__LINKEDIT".utf8) + Array(repeating: UInt8(0), count: 6)) {
                    linkeditFileRanges.append((offset, bytes))
                }
                hasSegment = true
                for index in 0..<sectionCount {
                    let section = cursor + 72 + index * 80
                    let flags = word(section + 64) & 0xff
                    let sectionOffset = UInt64(word(section + 48)), sectionBytes = wide(section + 40)
                    if flags != 1 && flags != 0xc && flags != 0x12 { // zerofill has no file bytes
                        guard inFile(sectionOffset, sectionBytes), sectionOffset >= offset,
                              sectionOffset - offset <= bytes, sectionBytes <= bytes - (sectionOffset - offset) else { throw invalid() }
                        if filetype == 1 && sectionBytes > 0 { occupiedObjectRanges.append((sectionOffset, sectionBytes)) }
                    }
                    let relocations = UInt64(word(section + 56)), relocationCount = UInt64(word(section + 60))
                    guard inFile(relocations, relocationCount * 8) else { throw invalid() }
                    if relocationCount > 0 { occupiedObjectRanges.append((relocations, relocationCount * 8)) }
                    if flags == 1 || flags == 0xc || flags == 0x12 {
                        guard relocationCount == 0 else { throw invalid() }
                    }
                }
            } else if command == 0xc || command == 0xd || command == 0xe || command == 0x8000001c {
                guard size >= 24 else { throw invalid() }
                let offset = Int(word(cursor + 8))
                // Dylib commands (LC_LOAD_DYLIB/LC_ID_DYLIB, 0xc/0xd) have a 24-byte
                // header before the path string. LC_LOAD_DYLINKER (0xe) and LC_RPATH
                // (0x8000001c) are 12-byte commands whose string begins right after
                // cmd/cmdsize, so accept their real minimum offset of 12.
                let minStringOffset = (command == 0xe || command == 0x8000001c) ? 12 : 24
                guard offset >= minStringOffset, offset < size else { throw invalid() }
                let bytes = data[(cursor + offset)..<(cursor + size)]
                guard let nul = bytes.firstIndex(of: 0),
                      let string = String(data: data[(cursor + offset)..<nul], encoding: .utf8) else { throw invalid() }
                if command == 0xc { dependencies.append(string) }
                else if command == 0xd { installNames.append(string) }
                // LC_LOAD_DYLINKER / LC_RPATH: bounds-validated only, never trusted as output metadata.
            } else if command == 0x2 {
                guard size == 24, symbolCount == nil else { throw invalid() }
                let symbols = UInt64(word(cursor + 8)), count = UInt64(word(cursor + 12))
                let strings = UInt64(word(cursor + 16)), length = UInt64(word(cursor + 20))
                guard inFile(symbols, count * 16), inFile(strings, length),
                      count == 0 || length > 0 else { throw invalid() }
                if filetype == 1 {
                    if count > 0 { occupiedObjectRanges.append((symbols, count * 16)) }
                    if length > 0 { occupiedObjectRanges.append((strings, length)) }
                }
                if length > 0 { guard data[Int(strings + length - 1)] == 0 else { throw invalid() } }
                for index in 0..<Int(count) {
                    guard UInt64(word(Int(symbols) + index * 16)) < length else { throw invalid() }
                }
                symbolCount = count
            } else if command == 0xb {
                guard size == 80, symbolRanges.isEmpty else { throw invalid() }
                for field in [8, 16, 24] {
                    let start = UInt64(word(cursor + field)), itemCount = UInt64(word(cursor + field + 4))
                    symbolRanges.append((start, itemCount))
                }
                for (field, stride) in [(32, 8), (40, 56), (48, 4), (56, 4), (64, 8), (72, 8)] {
                    let start = UInt64(word(cursor + field)), itemCount = UInt64(word(cursor + field + 4))
                    let (byteCount, overflow) = itemCount.multipliedReportingOverflow(by: UInt64(stride))
                    guard !overflow, inFile(start, byteCount) else { throw invalid() }
                    if filetype == 1 && byteCount > 0 { occupiedObjectRanges.append((start, byteCount)) }
                }
            } else if command == 0x32 {
                guard size >= 24, Int(word(cursor + 20)) <= (size - 24) / 8,
                      size == 24 + Int(word(cursor + 20)) * 8 else { throw invalid() }
            } else if command == 0x2c { // LC_ENCRYPTION_INFO_64 (not 32-bit)
                guard size == 24, encryptionRange == nil else {
                    throw invalid("encryption_command_size_or_duplicate")
                }
                guard word(cursor + 16) == 0 else { throw invalid("encrypted_output_cryptid_nonzero") }
                guard word(cursor + 20) == 0 else { throw invalid("encryption_reserved_padding_nonzero") }
                let offset = UInt64(word(cursor + 8)), bytes = UInt64(word(cursor + 12))
                guard inFile(offset, bytes), offset >= UInt64(end) else { throw invalid("encryption_range_outside_payload") }
                encryptionRange = (offset, bytes)
            } else if command == 0x80000028 {
                guard size == 24, !hasMain else { throw invalid("duplicate_or_malformed_lc_main") }
                let entry = wide(cursor + 8)
                guard inFile(entry, 4) else { throw invalid("lc_main_entry_outside_file") }
                hasMain = true
            } else if command == 0x25 || command == 0x2a {
                guard size == 16 else { throw invalid() }
            } else if command == 0x1b {
                guard size == 24 else { throw invalid() }
            } else if command == 0x2e {
                guard size == 16, optimizationHintRange == nil else {
                    throw invalid("optimization_hint_command_size_or_duplicate")
                }
                let offset = UInt64(word(cursor + 8)), bytes = UInt64(word(cursor + 12))
                guard bytes > 0, inFile(offset, bytes), offset >= UInt64(end) else {
                    throw invalid("optimization_hint_range_outside_payload")
                }
                optimizationHintRange = (offset, bytes)
            } else if command == 0x80000022 {
                guard size == 48, !hasClassicDyldInfo else { throw invalid("classic_dyld_info_command_size_or_duplicate") }
                for field in stride(from: 8, through: 40, by: 8) {
                    guard inFile(UInt64(word(cursor + field)), UInt64(word(cursor + field + 4))) else { throw invalid() }
                }
                hasClassicDyldInfo = true
            } else if command == 0x80000034 {
                guard size == 16, !hasChainedFixups else { throw invalid("chained_fixups_command_size_or_duplicate") }
                guard inFile(UInt64(word(cursor + 8)), UInt64(word(cursor + 12))) else { throw invalid() }
                hasChainedFixups = true
            } else { // allowlisted linkedit_data_command only
                guard size == 16, inFile(UInt64(word(cursor + 8)), UInt64(word(cursor + 12))) else { throw invalid() }
            }
            cursor += size
        }
        guard cursor == end, hasSegment else { throw invalid() }
        switch fixupPolicy {
        case .any:
            break
        case .classic:
            guard hasClassicDyldInfo, !hasChainedFixups else {
                throw invalid("classic_dyld_info_required_and_chained_fixups_forbidden")
            }
        case .xcodeCompatible:
            if architecture == .arm64e {
                guard hasChainedFixups else { throw invalid("arm64e_chained_fixups_required") }
            } else {
                guard hasClassicDyldInfo, !hasChainedFixups else {
                    throw invalid("arm64_classic_dyld_info_required")
                }
            }
        }
        for (start, count) in symbolRanges {
            guard let total = symbolCount, start <= total, count <= total - start else { throw invalid() }
        }
        if let (offset, bytes) = encryptionRange {
            guard textFileRanges.count == 1, textFileRanges.contains(where: { start, length in
                offset >= start && offset - start <= length && bytes <= length - (offset - start)
            }) else { throw invalid("encryption_range_outside_text_segment") }
        }
        if let (offset, bytes) = optimizationHintRange {
            if filetype == 1 {
                // MH_OBJECT has one anonymous segment and the linker-hint blob is
                // hidden from its visible section table. Bound it to the file,
                // after load commands, and disjoint from all known object data.
                let overlapsKnownData = occupiedObjectRanges.contains { start, length in
                    offset < start + length && start < offset + bytes
                }
                guard offset >= UInt64(end), !overlapsKnownData else {
                    throw invalid("optimization_hint_overlaps_object_data")
                }
            } else {
                let inLinkedit = linkeditFileRanges.count == 1 && linkeditFileRanges.contains { start, length in
                    offset >= start && offset - start <= length && bytes <= length - (offset - start)
                }
                guard inLinkedit else { throw invalid("optimization_hint_outside_linkedit") }
            }
        }
        // A tweak or daemon may legitimately link Apple frameworks (UIKit, Foundation,
        // Security, ...), so the dependency rule admits any absolute system library or
        // framework below /usr/lib or /System/Library. Project-relative, @rpath,
        // non-system and malformed paths stay rejected, so an output still cannot
        // smuggle a dependency on user-supplied code.
        func isSystemDependency(_ path: String) -> Bool {
            guard path.hasPrefix("/"), !path.contains("//"), !path.contains("/../"),
                  !path.contains("/./") else { return false }
            return path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/")
        }
        if filetype == 6 {
            guard dependencies.count <= 64, dependencies.allSatisfy(isSystemDependency),
                  installNames == ["@rpath/" + name] else {
                throw invalid("dependency_or_install_name_mismatch")
            }
        } else if filetype == 2 {
            guard hasMain else { throw invalid("executable_missing_lc_main") }
            guard installNames.isEmpty, dependencies.count <= 64,
                  dependencies.allSatisfy(isSystemDependency) else {
                throw invalid("executable_dependency_mismatch")
            }
        } else {
            guard dependencies.isEmpty, installNames.isEmpty else { throw invalid() }
        }
        return Self(name: name, bytes: data.count, sha256: digest(data), architecture: architecture.rawValue, filetype: filetype)
    }
}

/// Independent reader for the ad-hoc signature that the in-process ld64 embeds
/// with `-adhoc_codesign`. It verifies the SuperBlob, the CodeDirectory header and
/// every SHA-256 code slot against the real file bytes. When expected entitlements
/// are supplied, it also verifies the embedded entitlement blob byte-for-byte and
/// its CodeDirectory special-slot hash. It never loads the binary.
struct EmbeddedCodeSignatureReport: Equatable, Sendable {
    let identifier: String
    let codeSlots: Int
    let specialSlots: Int
    let fileOffset: UInt64
    let byteCount: UInt64
    let adHoc: Bool
    let entitlementsPresent: Bool
    let entitlementsBytes: Int
}

enum EmbeddedCodeSignatureError: Error, Equatable, LocalizedError, Sendable {
    case missingSignature
    case malformed(String)
    case codeSlotMismatch(Int)

    var errorDescription: String? {
        switch self {
        case .missingSignature: return "Mach-O has no embedded ad-hoc code signature"
        case .malformed(let rule): return "code signature rejected: \(rule)"
        case .codeSlotMismatch(let slot): return "code signature slot \(slot) does not match the file bytes"
        }
    }
}

enum EmbeddedCodeSignature {
    static let magicEmbeddedSignature: UInt32 = 0xfade0cc0
    static let magicCodeDirectory: UInt32 = 0xfade0c02
    static let magicEntitlements: UInt32 = 0xfade7171
    static let slotCodeDirectory: UInt32 = 0
    static let slotEntitlements: UInt32 = 5
    static let slotCMS: UInt32 = 0x10000

    static func verify(_ data: Data, expectedEntitlements: Data? = nil) throws -> EmbeddedCodeSignatureReport {
        let origin = data.startIndex
        func le32(_ offset: Int) -> UInt32? {
            guard offset >= 0, origin + offset + 4 <= data.endIndex else { return nil }
            let index = origin + offset
            return UInt32(data[index]) | (UInt32(data[index + 1]) << 8) |
                (UInt32(data[index + 2]) << 16) | (UInt32(data[index + 3]) << 24)
        }
        func be32(_ offset: Int) -> UInt32? {
            guard offset >= 0, origin + offset + 4 <= data.endIndex else { return nil }
            let index = origin + offset
            return (UInt32(data[index]) << 24) | (UInt32(data[index + 1]) << 16) |
                (UInt32(data[index + 2]) << 8) | UInt32(data[index + 3])
        }
        func byte(_ offset: Int) -> UInt8? {
            guard offset >= 0, origin + offset < data.endIndex else { return nil }
            return data[origin + offset]
        }
        func slice(_ offset: Int, _ count: Int) -> Data? {
            guard offset >= 0, count >= 0, origin + offset + count <= data.endIndex else { return nil }
            return data[(origin + offset)..<(origin + offset + count)]
        }

        guard let magic = le32(0), magic == 0xfeedfacf,
              let commandCount = le32(16), let commandBytes = le32(20) else {
            throw EmbeddedCodeSignatureError.malformed("not a 64-bit Mach-O")
        }
        let commandsEnd = 32 + Int(commandBytes)
        guard commandCount > 0, commandCount <= 4096, Int(commandBytes) >= Int(commandCount) * 8,
              commandsEnd <= data.count else {
            throw EmbeddedCodeSignatureError.malformed("load command bounds")
        }
        var cursor = 32
        var signatureOffset: UInt64?
        var signatureSize: UInt64?
        for _ in 0..<Int(commandCount) {
            guard let command = le32(cursor), let size = le32(cursor + 4),
                  size >= 8, cursor + Int(size) <= commandsEnd else {
                throw EmbeddedCodeSignatureError.malformed("load command layout")
            }
            if command == 0x1d {
                guard size == 16, signatureOffset == nil,
                      let offset = le32(cursor + 8), let bytes = le32(cursor + 12) else {
                    throw EmbeddedCodeSignatureError.malformed("LC_CODE_SIGNATURE layout")
                }
                signatureOffset = UInt64(offset)
                signatureSize = UInt64(bytes)
            }
            cursor += Int(size)
        }
        guard cursor == commandsEnd else { throw EmbeddedCodeSignatureError.malformed("load command walk") }
        guard let offset = signatureOffset, let size = signatureSize, size > 0 else {
            throw EmbeddedCodeSignatureError.missingSignature
        }
        guard offset <= UInt64(data.count), size <= UInt64(data.count) - offset,
              size <= UInt64(Int.max), offset + size == UInt64(data.count),
              offset >= UInt64(commandsEnd), offset % 8 == 0 else {
            throw EmbeddedCodeSignatureError.malformed("signature outside file or not terminal")
        }
        let base = Int(offset)
        guard let blobMagic = be32(base), blobMagic == magicEmbeddedSignature,
              let length = be32(base + 4), let count = be32(base + 8) else {
            throw EmbeddedCodeSignatureError.malformed("embedded signature header")
        }
        guard UInt64(length) <= size, size - UInt64(length) < 8,
              let signaturePadding = slice(base + Int(length), Int(size - UInt64(length))),
              signaturePadding.allSatisfy({ $0 == 0 }),
              count > 0, count <= 32 else {
            throw EmbeddedCodeSignatureError.malformed("embedded signature index table")
        }
        let indexEnd = 12 + Int(count) * 8
        guard indexEnd <= Int(length) else {
            throw EmbeddedCodeSignatureError.malformed("embedded signature index table")
        }
        var codeDirectoryOffset: Int?
        var entitlementsOffset: Int?
        var hasCMS = false
        var indexedBlobs: [(type: UInt32, offset: Int, length: Int)] = []
        var seenTypes: Set<UInt32> = []
        for index in 0..<Int(count) {
            guard let type = be32(base + 12 + index * 8),
                  let slotOffset = be32(base + 16 + index * 8),
                  slotOffset >= UInt32(indexEnd), slotOffset <= length,
                  length - slotOffset >= 8, seenTypes.insert(type).inserted,
                  let blobLength = be32(base + Int(slotOffset) + 4), blobLength >= 8,
                  blobLength <= length - slotOffset else {
                throw EmbeddedCodeSignatureError.malformed("blob index layout or duplicate type")
            }
            indexedBlobs.append((type, Int(slotOffset), Int(blobLength)))
            if type == slotCMS { hasCMS = true }
            if type == slotCodeDirectory { codeDirectoryOffset = base + Int(slotOffset) }
            if type == slotEntitlements { entitlementsOffset = base + Int(slotOffset) }
        }
        let expectedTypes: Set<UInt32> = expectedEntitlements == nil
            ? [slotCodeDirectory] : [slotCodeDirectory, slotEntitlements]
        guard seenTypes == expectedTypes else {
            throw EmbeddedCodeSignatureError.malformed("unexpected or missing signature blob type")
        }
        indexedBlobs.sort { $0.offset < $1.offset }
        var nextBlobOffset = indexEnd
        for blob in indexedBlobs {
            guard blob.offset == nextBlobOffset else {
                throw EmbeddedCodeSignatureError.malformed("signature blobs overlap or leave gaps")
            }
            nextBlobOffset += blob.length
        }
        guard nextBlobOffset == Int(length) else {
            throw EmbeddedCodeSignatureError.malformed("signature blobs do not cover the SuperBlob")
        }
        guard let codeDirectoryEntry = indexedBlobs.first(where: { $0.type == slotCodeDirectory }),
              let cd = codeDirectoryOffset,
              let cdMagic = be32(cd), cdMagic == magicCodeDirectory,
              let cdLength = be32(cd + 4), let version = be32(cd + 8),
              let flags = be32(cd + 12),
              let hashOffset = be32(cd + 16), let identOffset = be32(cd + 20),
              let specialSlots = be32(cd + 24), let codeSlots = be32(cd + 28),
              let codeLimit = be32(cd + 32) else {
            throw EmbeddedCodeSignatureError.missingSignature
        }
        let expectedSpecialSlots: UInt32 = expectedEntitlements == nil ? 0 : slotEntitlements
        guard Int(cdLength) == codeDirectoryEntry.length,
              cdLength >= 0x58, cd + Int(cdLength) <= base + Int(length),
              version == 0x20400, flags & 0x2 != 0,
              codeSlots > 0, specialSlots == expectedSpecialSlots,
              UInt64(codeLimit) == offset, Int(identOffset) == 0x58 else {
            throw EmbeddedCodeSignatureError.malformed("CodeDirectory fields")
        }
        guard let hashSize = byte(cd + 36), let hashType = byte(cd + 37), let pageShift = byte(cd + 39) else {
            throw EmbeddedCodeSignatureError.malformed("CodeDirectory hash header")
        }
        guard hashSize == 32, hashType == 2, pageShift == 12 else {
            throw EmbeddedCodeSignatureError.malformed("hash policy \(hashType)/\(hashSize)/\(pageShift)")
        }
        let hashArray = cd + Int(hashOffset)
        let identStart = cd + Int(identOffset)
        guard identStart < cd + Int(cdLength), let identData = slice(identStart, cd + Int(cdLength) - identStart),
              let nul = identData.firstIndex(of: 0),
              let identifier = String(data: identData[identData.startIndex..<nul], encoding: .utf8),
              !identifier.isEmpty, identifier.utf8.count <= 256,
              Int(hashOffset) == Int(identOffset) + identifier.utf8.count + 1 + Int(specialSlots) * 32,
              hashArray + Int(codeSlots) * 32 == cd + Int(cdLength) else {
            throw EmbeddedCodeSignatureError.malformed("CodeDirectory identifier or hash layout")
        }
        let pageBytes = 1 << Int(pageShift)
        let expectedSlots = (Int(codeLimit) + pageBytes - 1) / pageBytes
        guard expectedSlots == Int(codeSlots) else {
            throw EmbeddedCodeSignatureError.malformed("code slot count \(codeSlots) != \(expectedSlots)")
        }
        for slot in 0..<Int(codeSlots) {
            let pageStart = slot * pageBytes
            let pageLength = min(pageBytes, Int(codeLimit) - pageStart)
            guard pageLength > 0, let page = slice(pageStart, pageLength) else {
                throw EmbeddedCodeSignatureError.malformed("code page \(slot) outside file")
            }
            var hasher = SHA256()
            hasher.update(data: page)
            let expected = Array(hasher.finalize())
            let slotStart = hashArray + slot * 32
            for index in 0..<32 where data[slotStart + index] != expected[index] {
                throw EmbeddedCodeSignatureError.codeSlotMismatch(slot)
            }
        }
        var entitlementPayloadBytes = 0
        if let entitlementsOffset {
            guard let magic = be32(entitlementsOffset), magic == magicEntitlements,
                  let blobLength = be32(entitlementsOffset + 4), blobLength >= 8,
                  entitlementsOffset >= base,
                  entitlementsOffset + Int(blobLength) <= base + Int(length),
                  specialSlots >= slotEntitlements else {
                throw EmbeddedCodeSignatureError.malformed("entitlements blob layout")
            }
            guard let blob = slice(entitlementsOffset, Int(blobLength)) else {
                throw EmbeddedCodeSignatureError.malformed("entitlements blob range")
            }
            var hasher = SHA256()
            hasher.update(data: blob)
            let expected = Array(hasher.finalize())
            let entitlementSlotStart = hashArray - Int(slotEntitlements) * 32
            guard entitlementSlotStart >= cd else {
                throw EmbeddedCodeSignatureError.malformed("entitlements special slot range")
            }
            for index in 0..<32 where data[entitlementSlotStart + index] != expected[index] {
                throw EmbeddedCodeSignatureError.malformed("entitlements special-slot hash mismatch")
            }
            let payload = Data(blob.dropFirst(8))
            entitlementPayloadBytes = payload.count
            if let expectedEntitlements, payload != expectedEntitlements {
                throw EmbeddedCodeSignatureError.malformed("embedded entitlements differ from the validated plist")
            }
        } else if expectedEntitlements != nil {
            throw EmbeddedCodeSignatureError.malformed("expected entitlements are missing")
        }
        if expectedEntitlements == nil, entitlementsOffset != nil {
            throw EmbeddedCodeSignatureError.malformed("unexpected entitlements blob")
        }
        return EmbeddedCodeSignatureReport(identifier: identifier, codeSlots: Int(codeSlots),
                                           specialSlots: Int(specialSlots), fileOffset: offset,
                                           byteCount: size, adHoc: !hasCMS,
                                           entitlementsPresent: entitlementsOffset != nil,
                                           entitlementsBytes: entitlementPayloadBytes)
    }
}

struct EmbeddedAdapterStep: Codable, Sendable {
    let operation: String
    let status: Int
    let stdout: String
    let stderr: String
}

struct EmbeddedAdapterResult: Codable, Sendable {
    // Constants are intentionally encoded but never restored as executable
    // capability from decoded JSON. Explicit keys document that contract.
    private enum CodingKeys: String, CodingKey {
        case state, reason, steps, artifacts, residentSamplesBytes, processLinkCount
        case temporaryOutputsRemoved, providerExecutable, outputExecutionAttempted
    }
    var state = "rejected"
    var reason = ""
    var steps: [EmbeddedAdapterStep] = []
    var artifacts: [EmbeddedAdapterArtifact] = []
    var residentSamplesBytes: [UInt64] = []
    var processLinkCount = 0
    var temporaryOutputsRemoved = true
    /// Ephemeral verified output for an explicit user-selected export flow.
    /// Intentionally omitted from Codable diagnostics and never executed.
    var capturedDylibData: Data? = nil
    let providerExecutable = false
    let outputExecutionAttempted = false
    var passed: Bool { state == "success" && temporaryOutputsRemoved }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(String.self, forKey: .state)
        reason = try values.decode(String.self, forKey: .reason)
        steps = try values.decode([EmbeddedAdapterStep].self, forKey: .steps)
        artifacts = try values.decode([EmbeddedAdapterArtifact].self, forKey: .artifacts)
        residentSamplesBytes = try values.decode([UInt64].self, forKey: .residentSamplesBytes)
        processLinkCount = try values.decode(Int.self, forKey: .processLinkCount)
        temporaryOutputsRemoved = try values.decode(Bool.self, forKey: .temporaryOutputsRemoved)
        // Serialized diagnostics cannot restore runtime capability or binary output bytes.
        capturedDylibData = nil
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        try values.encode(reason, forKey: .reason)
        try values.encode(steps, forKey: .steps)
        try values.encode(artifacts, forKey: .artifacts)
        try values.encode(residentSamplesBytes, forKey: .residentSamplesBytes)
        try values.encode(processLinkCount, forKey: .processLinkCount)
        try values.encode(temporaryOutputsRemoved, forKey: .temporaryOutputsRemoved)
        try values.encode(false, forKey: .providerExecutable)
        try values.encode(false, forKey: .outputExecutionAttempted)
        // capturedDylibData is deliberately never serialized into UI JSON.
    }
}

private final class EmbeddedAdapterProcessState: @unchecked Sendable {
    static let native = EmbeddedAdapterProcessState()
    let queue = DispatchQueue(label: "minis.embedded-adapter.validation")
    // All access is confined to queue; every native adapter shares this state.
    var poisonReason: String?
    var links = 0
    var exhausted = false
    var initialResident: UInt64?
}

final class EmbeddedToolchainExecutionAdapter: @unchecked Sendable {
    static let shared = EmbeddedToolchainExecutionAdapter(bridge: EmbeddedNativeAdapterBridge())
    private let bridge: any EmbeddedAdapterBridge
    private let process: EmbeddedAdapterProcessState
    private var queue: DispatchQueue { process.queue }
    private var poisonReason: String? { get { process.poisonReason } set { process.poisonReason = newValue } }
    private var links: Int { get { process.links } set { process.links = newValue } }
    private var exhausted: Bool { get { process.exhausted } set { process.exhausted = newValue } }
    private var initialResident: UInt64? { get { process.initialResident } set { process.initialResident = newValue } }
    // The host app itself is already near 384 MiB before the first link.
    // Keep a hard admission ceiling, but leave enough headroom for one bounded
    // ld64 link; the independent lifetime-growth cap remains 64 MiB.
    private let maxResident: UInt64 = 448 * 1024 * 1024
    private let maxLifetimeGrowth: UInt64 = 64 * 1024 * 1024

    init(bridge: any EmbeddedAdapterBridge) {
        self.bridge = bridge
        self.process = bridge is EmbeddedNativeAdapterBridge ? .native : EmbeddedAdapterProcessState()
    }
    /// Identity only: tests can prove native instances cannot reset budgets.
    var processScopeID: ObjectIdentifier { ObjectIdentifier(process) }

    /// Owned input bytes only; no caller-controlled filesystem root. The link
    /// list can refer only to objects compiled and hashed in this same request.
    func execute(sources: [String: String], operations: [EmbeddedToolchainOperation],
                 architecture: EmbeddedToolchainArchitecture = .arm64,
                 captureDylib: Bool = false,
                 cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) async -> EmbeddedAdapterResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.run(sources: sources, operations: operations,
                                                           architecture: architecture,
                                                           captureDylib: captureDylib,
                                                           cancellation: cancellation))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// A dual build is one queue transaction: another request cannot consume
    /// link/RSS budget between slices. Reserve admission for two links up front.
    func executeUniversal(sources: [String: String], operations: [EmbeddedToolchainOperation],
                          cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) async
        -> EmbeddedUniversalExecutionResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.runUniversal(sources: sources,
                        operations: operations, cancellation: cancellation))
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func runUniversal(sources: [String: String], operations: [EmbeddedToolchainOperation],
                              cancellation: EmbeddedAdapterCancellation) -> EmbeddedUniversalExecutionResult {
        var reports: [EmbeddedAdapterResult] = []
        func failed(_ reason: String) -> EmbeddedUniversalExecutionResult {
            let diagnostics = reports.map { report in
                var value = report
                value.capturedDylibData = nil
                value.artifacts.removeAll()
                return value
            }
            return EmbeddedUniversalExecutionResult(reports: diagnostics, artifact: nil, data: nil, reason: reason)
        }
        guard !cancellation.isCancelled else { return failed("cancelled") }
        guard poisonReason == nil else { return failed(poisonReason ?? "native state poisoned") }
        guard !exhausted, links <= 1 else {
            return failed("dual build needs two remaining native links; restart the app")
        }
        guard let last = operations.last, case let .link(_, outputName, _) = last,
              operations.filter({ if case .link = $0 { return true }; return false }).count == 1 else {
            return failed("dual build requires one final structured link per target")
        }
        for target in [EmbeddedToolchainArchitecture.arm64, .arm64e] {
            let report = run(sources: sources, operations: operations, architecture: target,
                             captureDylib: true, cancellation: cancellation)
            reports.append(report)
            guard report.passed, report.capturedDylibData != nil else {
                return failed(target.rawValue + ": " + (report.reason.isEmpty ? report.state : report.reason))
            }
        }
        do {
            guard let arm64 = reports[0].capturedDylibData, let arm64e = reports[1].capturedDylibData else {
                return failed("missing inspected target output")
            }
            let fat = try EmbeddedToolchainUniversalBinary.merge(arm64: arm64, arm64e: arm64e,
                name: outputName, cancellation: cancellation)
            let artifact = try EmbeddedToolchainUniversalBinary.inspect(fat, name: outputName)
            // Include fat allocation/inspection in native lifetime RSS admission.
            var final = reports[1]
            guard sampleMemory(into: &final) else {
                reports[1] = final
                return failed(final.reason)
            }
            reports[1] = final
            guard !cancellation.isCancelled else { return failed("cancelled") }
            // Aggregate output owns the sole export capability; reports keep no thin bytes.
            for index in reports.indices { reports[index].capturedDylibData = nil }
            return EmbeddedUniversalExecutionResult(reports: reports, artifact: artifact, data: fat, reason: "")
        } catch { return failed(String(describing: error)) }
    }

    private func run(sources: [String: String], operations: [EmbeddedToolchainOperation],
                     architecture: EmbeddedToolchainArchitecture,
                     captureDylib: Bool,
                     cancellation: EmbeddedAdapterCancellation) -> EmbeddedAdapterResult {
        var result = EmbeddedAdapterResult()
        func finish() -> EmbeddedAdapterResult {
            result.processLinkCount = links
            return result
        }
        guard poisonReason == nil else {
            result.state = "poisoned"; result.reason = poisonReason!; return finish()
        }
        guard !exhausted, links < 3 else {
            result.state = "budget_exceeded"; result.reason = "adapter process budget exhausted; restart the app"; return finish()
        }
        guard !cancellation.isCancelled else { result.state = "cancelled"; return finish() }
        let status = bridge.capability()
        guard status["compiler_linked"] == "yes", status["verification"] == "passed",
              status["resource_headers"] == "present", status["sdk"] == "present",
              status["state"] == "ready", status["host_architecture"] == "arm64" else {
            result.state = "unavailable"; result.reason = "fixed-runtime toolchain gates are not ready"; return finish()
        }
        guard !sources.isEmpty, sources.count <= 4, !operations.isEmpty, operations.count <= 6,
              operations.filter({ if case .link = $0 { return true }; return false }).count <= 1,
              !captureDylib || operations.contains(where: { if case .link = $0 { return true }; return false }) else {
            result.reason = "bounded request requires 1-4 sources, 1-6 operations and at most one link"; return finish()
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("minis-adapter-" + UUID().uuidString, isDirectory: true)
        var rootCreated = false
        do {
            // Reject unsupported language features before allocating compiler state.
            for (name, source) in sources {
                guard Self.safeName(name), ["c", "m"].contains(URL(fileURLWithPath: name).pathExtension),
                      let data = source.data(using: .ascii), data.count > 0, data.count <= 128 * 1024,
                      Self.isSelfContained(source) else {
                    throw EmbeddedAdapterError.rejected("only bounded self-contained ASCII C/Objective-C without preprocessing, assembly or pragmas is accepted")
                }
            }
            // Own every pathname and do not overwrite a source/intermediate.
            var known = Set(sources.keys)
            var compiled = Set<String>()
            for operation in operations {
                switch operation {
                case let .compile(source, output, language):
                    guard sources[source] != nil, Self.safeName(output), !known.contains(output),
                          output.hasSuffix(".o"), source.hasSuffix(language == .c ? ".c" : ".m") else {
                        throw EmbeddedAdapterError.rejected("compile must name a supplied source and a fresh flat output")
                    }
                    compiled.insert(output); known.insert(output)
                case let .link(objects, output, installName):
                    guard Self.safeName(output), output.hasSuffix(".dylib"), !known.contains(output), !objects.isEmpty,
                          Set(objects).count == objects.count, objects.allSatisfy({ compiled.contains($0) }),
                          installName == "@rpath/" + output else {
                        throw EmbeddedAdapterError.rejected("link accepts only distinct objects produced earlier in this run and a matching @rpath output")
                    }
                    known.insert(output)
                }
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            rootCreated = true
            for (name, source) in sources {
                try Data(source.utf8).write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
            }
            var produced: [String: String] = [:]
            operationLoop: for operation in operations {
                if cancellation.isCancelled { result.state = "cancelled"; break }
                guard sampleMemory(into: &result) else { break }
                if let error = operation.validationError(root: root) { throw EmbeddedAdapterError.rejected(error) }
                let partial = root.appendingPathComponent("partial-" + UUID().uuidString)
                let name: String
                let type: UInt32
                let call: EmbeddedAdapterCall
                switch operation {
                case let .compile(source, output, language):
                    name = output; type = 1
                    var arguments = ["-triple", architecture.rawValue + "-apple-ios15.0", "-target-cpu", architecture.cpu,
                                     "-emit-obj", "-ffreestanding", "-std=c11", "-O1",
                                     "-nostdsysteminc", "-nobuiltininc", "-ferror-limit", "16",
                                     "-o", partial.path, "-x", language.rawValue]
                    if architecture == .arm64e {
                        // Upstream clang leaves pointer authentication off for
                        // an arm64e triple; without these the slice is arm64
                        // code labelled arm64e and any function pointer handed
                        // to system code fails authentication at runtime.
                        arguments += ["-fptrauth-returns", "-fptrauth-calls"]
                    }
                    if language == .objectiveC { arguments += ["-fobjc-runtime=ios-15.0", "-fobjc-arc"] }
                    arguments.append(root.appendingPathComponent(source).path)
                    call = bridge.compile(arguments)
                case let .link(objects, output, installName):
                    name = output; type = 6
                    for object in objects {
                        let data = try boundedRead(root.appendingPathComponent(object))
                        guard produced[object] == EmbeddedAdapterArtifact.digest(data) else {
                            throw EmbeddedAdapterError.poisoned("an intermediate object changed after verification")
                        }
                    }
                    let stub = try bridge.verifiedLibSystemStub()
                    guard stub.count >= 1024, stub.count <= 2 * 1024 * 1024 else {
                        throw EmbeddedAdapterError.rejected("verified library stub is outside the byte budget")
                    }
                    let stubURL = root.appendingPathComponent("libSystem.B.tbd")
                    try stub.write(to: stubURL, options: .withoutOverwriting)
                    let hasObjectiveC = operations.contains { operation in
                        if case let .compile(_, _, language) = operation { return language == .objectiveC }
                        return false
                    }
                    var runtimeInputs = [stubURL.path]
                    if hasObjectiveC {
                        let objcStub = try bridge.verifiedObjCRuntimeStub()
                        guard objcStub.count >= 1024, objcStub.count <= 2 * 1024 * 1024 else {
                            throw EmbeddedAdapterError.rejected("verified Objective-C runtime stub is outside the byte budget")
                        }
                        let objcURL = root.appendingPathComponent("libobjc.A.tbd")
                        try objcStub.write(to: objcURL, options: .withoutOverwriting)
                        runtimeInputs.append(objcURL.path)
                    }
                    guard !cancellation.isCancelled else { result.state = "cancelled"; break operationLoop }
                    // Reserve the lifetime link budget before invoking ld64.
                    links += 1
                    var linkerArguments = ["-arch", architecture.rawValue]
                    if architecture == .arm64 { linkerArguments.append("-no_fixup_chains") }
                    linkerArguments += ["-dylib", "-platform_version", "ios", "15.0", "16.5",
                                        "-install_name", installName, "-o", partial.path]
                    call = bridge.link(linkerArguments +
                                       objects.map { root.appendingPathComponent($0).path } + runtimeInputs)
                }
                if result.state == "cancelled" { break }
                result.steps.append(EmbeddedAdapterStep(operation: name, status: call.status,
                    stdout: String(call.stdout.prefix(4096)), stderr: String(call.stderr.prefix(4096))))
                let memoryAllowed = sampleMemory(into: &result)
                if !(0...4).contains(call.status) || call.status == 3 || call.stderr.contains("internal assertion") {
                    throw EmbeddedAdapterError.poisoned("internal bridge failure; restart the app before another adapter request")
                }
                if cancellation.isCancelled { result.state = "cancelled"; break }
                guard memoryAllowed else { break }
                guard call.status == 0 else {
                    result.state = call.status == 4 ? "unavailable" : "diagnostics"
                    result.reason = "compiler/linker rejected the bounded input"; break
                }
                let data = try boundedRead(partial)
                let artifact = try EmbeddedAdapterArtifact.inspect(data, name: name, filetype: type,
                    architecture: architecture, fixupPolicy: type == 6 ? .xcodeCompatible : .any)
                if captureDylib && type == 6 { result.capturedDylibData = data }
                try fm.moveItem(at: partial, to: root.appendingPathComponent(name))
                produced[name] = artifact.sha256
                result.artifacts.append(artifact)
                result.state = "success"
            }
        } catch EmbeddedAdapterError.poisoned(let reason) {
            poisonReason = reason; result.state = "poisoned"; result.reason = reason
        } catch EmbeddedAdapterError.rejected(let reason) {
            result.state = "rejected"; result.reason = reason
        } catch {
            result.state = "poisoned"; result.reason = "adapter I/O or unexpected failure: " + error.localizedDescription
            poisonReason = result.reason
        }
        if rootCreated {
            do {
                try fm.removeItem(at: root)
                guard !fm.fileExists(atPath: root.path) else { throw EmbeddedAdapterError.poisoned("cleanup left a private run directory") }
            } catch {
                result.temporaryOutputsRemoved = false
                result.state = "poisoned"; result.reason = "temporary-output cleanup failed; restart the app"
                poisonReason = result.reason
            }
        }
        // Final admission sample includes inspection/hash/cleanup allocations.
        // The final cancellation read is the completion linearization point;
        // a late cancellation never overwrites a poisoned/cleanup-failure state.
        if result.state == "success" {
            _ = sampleMemory(into: &result)
            if result.state == "success", cancellation.isCancelled { result.state = "cancelled" }
        }
        // Metadata is inspection evidence, not an available output artifact.
        // Failed/cancelled batches never expose even partial-success metadata.
        if result.state != "success" {
            result.artifacts.removeAll()
            result.capturedDylibData = nil
        }
        return finish()
    }

    private func sampleMemory(into result: inout EmbeddedAdapterResult) -> Bool {
        let resident = bridge.residentBytes()
        result.residentSamplesBytes.append(resident)
        guard resident > 0 else {
            result.state = "unavailable"; result.reason = "resident memory sampling unavailable"; return false
        }
        if initialResident == nil { initialResident = resident }
        let baseline = initialResident ?? resident
        guard resident < maxResident, resident <= baseline || resident - baseline < maxLifetimeGrowth else {
            exhausted = true
            result.state = "budget_exceeded"; result.reason = "resident memory budget exhausted; restart the app"
            return false
        }
        return true
    }

    private func boundedRead(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw EmbeddedAdapterError.poisoned("missing or unsafe generated output") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= 16 * 1024 * 1024 else {
            throw EmbeddedAdapterError.poisoned("generated output is not a bounded regular file")
        }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count == Int(attributes.st_size) else { throw EmbeddedAdapterError.poisoned("generated output changed during inspection") }
        return data
    }

    static func safeName(_ name: String) -> Bool {
        guard let range = name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.(c|m|o|dylib)$", options: .regularExpression) else { return false }
        return range == (name.startIndex..<name.endIndex)
    }

    static func isSelfContained(_ source: String) -> Bool {
        // First phase deliberately has no project/SDK header dependency scanner.
        // Reject every preprocessing spelling (including digraphs/trigraphs and
        // escaped newlines), assembler filesystem directives, and pragma/module
        // injection. This is a restrictive subset, not a general C sandbox.
        guard source.utf8.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else { return false }
        return !["#", "\\", "%:", "??", "asm", "_Pragma", "__pragma", "@import"].contains(where: source.contains)
    }
}
