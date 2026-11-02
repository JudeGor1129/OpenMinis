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
    func compile(_ arguments: [String]) -> EmbeddedAdapterCall
    func link(_ arguments: [String]) -> EmbeddedAdapterCall
}

struct EmbeddedNativeAdapterBridge: EmbeddedAdapterBridge {
    static let libSystemSHA256 = "1ab02266a39491a8bd5a91ba36d5c8c8c6ac6efb92099e1091a1fd2370fc53e3"
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
        guard let sdk = capability()["sysroot"], sdk.hasSuffix("/iPhoneOS16.5.sdk") else {
            throw EmbeddedAdapterError.rejected("adapter validation requires the pinned SDK16.5 libSystem stub")
        }
        let path = URL(fileURLWithPath: sdk).appendingPathComponent("usr/lib/libSystem.B.tbd").path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw EmbeddedAdapterError.rejected("libSystem stub is missing or a symlink") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size >= 1024, attributes.st_size <= 2 * 1024 * 1024 else {
            throw EmbeddedAdapterError.rejected("libSystem stub is not a bounded regular file")
        }
        let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard data.count >= 1024, data.count <= 2 * 1024 * 1024,
              EmbeddedAdapterArtifact.digest(data) == Self.libSystemSHA256 else {
            throw EmbeddedAdapterError.rejected("libSystem stub differs from the pinned SDK16.5 content")
        }
        return data
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
}

final class EmbeddedAdapterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

enum EmbeddedAdapterError: Error {
    case rejected(String)
    case poisoned(String)
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

    /// Thin arm64 only. Validate command/segment bounds before reporting an
    /// artifact. Never mmap, load, sign or execute generated code.
    static func inspect(_ data: Data, name: String, filetype: UInt32) throws -> Self {
        func invalid(_ rule: String = "structure", line: Int = #line) -> EmbeddedAdapterError {
            .poisoned("Mach-O output rejected: \(rule) (check_line=\(line))")
        }
        guard [UInt32(1), 6].contains(filetype) else { throw invalid("unexpected_filetype=\(filetype)") }
        guard data.count >= 32, data.count <= 16 * 1024 * 1024 else { throw invalid("output_size_out_of_bounds") }
        func word(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
                UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        func wide(_ offset: Int) -> UInt64 { UInt64(word(offset)) | UInt64(word(offset + 4)) << 32 }
        guard word(0) == 0xfeedfacf, word(4) == 0x0100000c,
              word(8) & 0x00ffffff == 0, word(12) == filetype else { throw invalid() }
        let count = Int(word(16)), length = Int(word(20))
        guard count > 0, count <= 4096, length >= count * 8, length <= data.count - 32 else { throw invalid() }
        var cursor = 32
        let end = cursor + length
        var hasSegment = false
        var dependencies: [String] = []
        var installNames: [String] = []
        var symbolCount: UInt64?
        var symbolRanges: [(UInt64, UInt64)] = []
        var textFileRanges: [(UInt64, UInt64)] = []
        var encryptionRange: (UInt64, UInt64)?
        let objectCommands: Set<UInt32> = [0x19, 0x2, 0xb, 0x32, 0x25, 0x29]
        // Pinned ld64 also emits LC_ENCRYPTION_INFO_64 for iOS dylibs by
        // default, with cryptid=0. This is metadata, not encrypted content.
        // Admit only its bounded, unencrypted form; never bypass inspection.
        let dylibCommands = objectCommands.union([0xc, 0xd, 0x1b, 0x80000022, 0x26, 0x1d,
                                                  0x2a, 0x80000033, 0x80000034, 0x2c])
        func inFile(_ offset: UInt64, _ bytes: UInt64) -> Bool {
            offset <= UInt64(data.count) && bytes <= UInt64(data.count) - offset
        }
        for _ in 0..<count {
            guard cursor + 8 <= end else { throw invalid() }
            let command = word(cursor), size = Int(word(cursor + 4))
            if command == 0x2c && size != 24 { throw invalid("encryption_command_size_or_duplicate") }
            guard size >= 8, size % 8 == 0, size <= end - cursor else { throw invalid() }
            // Unknown/unsupported commands are rejected, not silently skipped.
            guard (filetype == 1 ? objectCommands : dylibCommands).contains(command) else {
                throw invalid("unsupported_load_command=0x\(String(command, radix: 16)),offset=\(cursor)")
            }
            if command == 0x19 {
                guard size >= 72 else { throw invalid() }
                let sectionCount = Int(word(cursor + 64))
                guard sectionCount <= (size - 72) / 80, size == 72 + sectionCount * 80 else { throw invalid() }
                let offset = wide(cursor + 40), bytes = wide(cursor + 48)
                guard inFile(offset, bytes) else { throw invalid() }
                if data[(cursor + 8)..<(cursor + 24)].elementsEqual(Array("__TEXT".utf8) + Array(repeating: UInt8(0), count: 10)) {
                    textFileRanges.append((offset, bytes))
                }
                hasSegment = true
                for index in 0..<sectionCount {
                    let section = cursor + 72 + index * 80
                    let flags = word(section + 64) & 0xff
                    if flags != 1 && flags != 0xc && flags != 0x12 { // zerofill has no file bytes
                        let sectionOffset = UInt64(word(section + 48)), sectionBytes = wide(section + 40)
                        guard inFile(sectionOffset, sectionBytes), sectionOffset >= offset,
                              sectionOffset - offset <= bytes, sectionBytes <= bytes - (sectionOffset - offset) else { throw invalid() }
                    }
                    let relocations = UInt64(word(section + 56)), relocationCount = UInt64(word(section + 60))
                    guard inFile(relocations, relocationCount * 8) else { throw invalid() }
                    if flags == 1 || flags == 0xc || flags == 0x12 {
                        guard relocationCount == 0 else { throw invalid() }
                    }
                }
            } else if command == 0xc || command == 0xd {
                guard size >= 24 else { throw invalid() }
                let offset = Int(word(cursor + 8))
                guard offset >= 24, offset < size else { throw invalid() }
                let bytes = data[(cursor + offset)..<(cursor + size)]
                guard let nul = bytes.firstIndex(of: 0),
                      let string = String(data: data[(cursor + offset)..<nul], encoding: .utf8) else { throw invalid() }
                if command == 0xc { dependencies.append(string) } else { installNames.append(string) }
            } else if command == 0x2 {
                guard size == 24, symbolCount == nil else { throw invalid() }
                let symbols = UInt64(word(cursor + 8)), count = UInt64(word(cursor + 12))
                let strings = UInt64(word(cursor + 16)), length = UInt64(word(cursor + 20))
                guard inFile(symbols, count * 16), inFile(strings, length),
                      count == 0 || length > 0 else { throw invalid() }
                if length > 0 { guard data[Int(strings + length - 1)] == 0 else { throw invalid() } }
                for index in 0..<Int(count) {
                    guard UInt64(word(Int(symbols) + index * 16)) < length else { throw invalid() }
                }
                symbolCount = count
            } else if command == 0xb {
                guard size == 80, symbolRanges.isEmpty else { throw invalid() }
                for field in [8, 16, 24] {
                    symbolRanges.append((UInt64(word(cursor + field)), UInt64(word(cursor + field + 4))))
                }
                for (field, stride) in [(32, 8), (40, 56), (48, 4), (56, 4), (64, 8), (72, 8)] {
                    guard inFile(UInt64(word(cursor + field)), UInt64(word(cursor + field + 4)) * UInt64(stride)) else { throw invalid() }
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
            } else if command == 0x25 || command == 0x2a {
                guard size == 16 else { throw invalid() }
            } else if command == 0x1b {
                guard size == 24 else { throw invalid() }
            } else if command == 0x80000022 {
                guard size == 48 else { throw invalid() }
                for field in stride(from: 8, through: 40, by: 8) {
                    guard inFile(UInt64(word(cursor + field)), UInt64(word(cursor + field + 4))) else { throw invalid() }
                }
            } else { // allowlisted linkedit_data_command only
                guard size == 16, inFile(UInt64(word(cursor + 8)), UInt64(word(cursor + 12))) else { throw invalid() }
            }
            cursor += size
        }
        guard cursor == end, hasSegment else { throw invalid() }
        for (start, count) in symbolRanges {
            guard let total = symbolCount, start <= total, count <= total - start else { throw invalid() }
        }
        if let (offset, bytes) = encryptionRange {
            guard textFileRanges.count == 1, textFileRanges.contains(where: { start, length in
                offset >= start && offset - start <= length && bytes <= length - (offset - start)
            }) else { throw invalid("encryption_range_outside_text_segment") }
        }
        if filetype == 6 {
            guard dependencies == ["/usr/lib/libSystem.B.dylib"], installNames == ["@rpath/" + name] else {
                throw invalid("dependency_or_install_name_mismatch")
            }
        } else {
            guard dependencies.isEmpty, installNames.isEmpty else { throw invalid() }
        }
        return Self(name: name, bytes: data.count, sha256: digest(data), architecture: "arm64", filetype: filetype)
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
    let providerExecutable = false
    let outputExecutionAttempted = false
    var passed: Bool { state == "success" && temporaryOutputsRemoved }
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
                 cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) async -> EmbeddedAdapterResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.run(sources: sources, operations: operations, cancellation: cancellation))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func run(sources: [String: String], operations: [EmbeddedToolchainOperation],
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
              operations.filter({ if case .link = $0 { return true }; return false }).count <= 1 else {
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
                    var arguments = ["-triple", "arm64-apple-ios15.0", "-target-cpu", "apple-a7",
                                     "-emit-obj", "-ffreestanding", "-std=c11", "-O1",
                                     "-nostdsysteminc", "-nobuiltininc", "-ferror-limit", "16",
                                     "-o", partial.path, "-x", language.rawValue]
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
                    guard !cancellation.isCancelled else { result.state = "cancelled"; break operationLoop }
                    // Reserve the lifetime link budget before invoking ld64.
                    links += 1
                    call = bridge.link(["-arch", "arm64", "-dylib", "-platform_version", "ios", "15.0", "16.5",
                                        "-install_name", installName, "-o", partial.path] +
                                       objects.map { root.appendingPathComponent($0).path } + [stubURL.path])
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
                let artifact = try EmbeddedAdapterArtifact.inspect(data, name: name, filetype: type)
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
        if result.state != "success" { result.artifacts.removeAll() }
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
