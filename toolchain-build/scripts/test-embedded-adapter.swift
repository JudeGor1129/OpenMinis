// Standalone executable contracts for the real EmbeddedToolchainExecutionAdapter.
// OMToolchain below is a compile-only native stub; FakeBridge is the injected
// seam. Neither implements an adapter, compiles C, links LLVM or runs output.
import Foundation
import Darwin

// Match the Objective-C import's Int rawValue and nullable NSString out params.
enum OMToolchainStatus: Int { case ok = 0, badArguments, diagnostics, internalError, unavailable }
enum OMToolchain {
    static func capabilityStatus() -> [String: String] { [:] }
    static func runCC1(_ arguments: [String], stdout: inout NSString?, stderr: inout NSString?) -> OMToolchainStatus {
        preconditionFailure("native compile-only stub must never be executed")
    }
    static func runLinker(_ arguments: [String], stdout: inout NSString?, stderr: inout NSString?) -> OMToolchainStatus {
        preconditionFailure("native compile-only stub must never be executed")
    }
}

enum MachOFixture {
    static func u32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func u64(_ value: UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func name(_ value: String) -> Data { var d = Data(value.utf8); d.append(Data(repeating: 0, count: 16 - d.count)); return d }
    static func patch(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data.replaceSubrange(offset..<(offset + 4), with: u32(value))
    }
    static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
    static func encryptionCommand(offset: UInt32, bytes: UInt32, cryptid: UInt32 = 0, pad: UInt32 = 0) -> Data {
        [UInt32(0x2c), 24, offset, bytes, cryptid, pad].reduce(into: Data()) { $0.append(u32($1)) }
    }
    static func commandOffset(_ command: UInt32, in data: Data) -> Int {
        func read(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        var cursor = 32
        for _ in 0..<read(16) {
            if read(cursor) == command { return cursor }
            cursor += Int(read(cursor + 4))
        }
        preconditionFailure("fixture command is missing")
    }
    static func adding(_ command: Data, to original: Data) -> Data {
        var data = original
        func read(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        let count = read(16), bytes = read(20), payload = Int(bytes) + 32
        var cursor = 32
        for _ in 0..<count {
            let commandID = read(cursor), commandSize = Int(read(cursor + 4))
            if commandID == 0x19 {
                let sectionCount = Int(read(cursor + 64))
                let fileOffset = Int(read(cursor + 40))
                let fileSize = Int(read(cursor + 48))
                if fileOffset >= payload {
                    patch(&data, cursor + 40, UInt32(fileOffset + command.count))
                }
                for field in [8, 16] {
                    let segmentField = cursor + field
                    let start = Int(read(segmentField))
                    let length = Int(read(segmentField + 4))
                    if start >= payload && length > 0 && start <= data.count && length <= data.count - start {
                        patch(&data, segmentField, UInt32(start + command.count))
                    }
                }
                for index in 0..<sectionCount {
                    let section = cursor + 72 + index * 80
                    let sectionOffset = Int(read(section + 48))
                    if sectionOffset >= payload { patch(&data, section + 48, UInt32(sectionOffset + command.count)) }
                }
            } else if commandID == 0x2c || commandID == 0x2e || commandID == 0x26 ||
                        commandID == 0x80000033 || commandID == 0x80000034 {
                let dataOffset = Int(read(cursor + 8))
                if dataOffset >= payload { patch(&data, cursor + 8, UInt32(dataOffset + command.count)) }
            }
            cursor += commandSize
        }
        data.insert(contentsOf: command, at: payload)
        var newCommandCursor = payload
        var newCommandCount: UInt32 = 0
        while newCommandCursor < payload + command.count {
            let size = Int(read(newCommandCursor + 4))
            precondition(size >= 8 && size <= payload + command.count - newCommandCursor)
            newCommandCursor += size
            newCommandCount += 1
        }
        patch(&data, 16, count + newCommandCount)
        patch(&data, 20, bytes + UInt32(command.count))
        return data
    }
    static func optimizationHintCommand(offset: UInt32, bytes: UInt32) -> Data {
        [UInt32(0x2e), 16, offset, bytes].reduce(into: Data()) { $0.append(u32($1)) }
    }
    static func linkeditSegment(offset: UInt32, bytes: UInt32) -> Data {
        var data = u32(0x19) + u32(72) + name("__LINKEDIT")
        data.append(u64(0)); data.append(u64(UInt64(bytes)))
        data.append(u64(UInt64(offset))); data.append(u64(UInt64(bytes)))
        data.append(u32(1)); data.append(u32(1)); data.append(u32(0)); data.append(u32(0))
        return data
    }
    static func objectWithOptimizationHint(duplicates: Bool = false) -> Data {
        let hint = Data(repeating: 0x5a, count: 8)
        let strings = Data([UInt8(0), UInt8(95), UInt8(102), UInt8(111), UInt8(111), UInt8(0)])
        let symbolBytes = 16
        let segmentCommandBytes = 72 + 80 // one anonymous segment and visible __text section
        let hintCommandCount = duplicates ? 2 : 1
        let commandBytes = segmentCommandBytes + hintCommandCount * 16 + 24 // LC_SEGMENT_64 + hints + LC_SYMTAB
        let textOffset = UInt32(32 + commandBytes)
        let symbolOffset = textOffset + 8
        let stringOffset = symbolOffset + UInt32(symbolBytes)
        let hintOffset = stringOffset + UInt32(strings.count)

        var segment = u32(0x19) + u32(UInt32(segmentCommandBytes)) + name("")
        segment.append(u64(0)); segment.append(u64(8))
        segment.append(u64(UInt64(textOffset))); segment.append(u64(UInt64(8 + symbolBytes + strings.count + hint.count)))
        segment.append(u32(7)); segment.append(u32(7)); segment.append(u32(1)); segment.append(u32(0))
        var textSection = name("__text")
        textSection.append(name("__TEXT")); textSection.append(u64(0)); textSection.append(u64(8))
        textSection.append(u32(textOffset))
        for value: UInt32 in [2, 0, 0, 0x80000400, 0, 0, 0] { textSection.append(u32(value)) }
        segment.append(textSection)

        var data = Data()
        for value in [UInt32(0xfeedfacf), 0x0100000c, 0, 1, UInt32(1 + hintCommandCount + 1), UInt32(commandBytes), 0, 0] {
            data.append(u32(value))
        }
        data.append(segment)
        for _ in 0..<hintCommandCount { data.append(optimizationHintCommand(offset: hintOffset, bytes: UInt32(hint.count))) }
        for value in [UInt32(0x2), UInt32(24), symbolOffset, 1, stringOffset, UInt32(strings.count)] { data.append(u32(value)) }
        data.append(Data([0xc0, 0x03, 0x5f, 0xd6, 0x1f, 0x20, 0x03, 0xd5]))
        data.append(Data(repeating: 0, count: symbolBytes)) // one bounded nlist_64 symbol
        data.append(strings); data.append(hint)
        return data
    }

    static func imageWithOptimizationHint(filetype: UInt32 = 6, installName: String = "",
                                          duplicates: Bool = false) -> Data {
        if filetype == 1 { return objectWithOptimizationHint(duplicates: duplicates) }
        var data = image(filetype: filetype, installName: installName)
        let hint = Data(repeating: 0x5a, count: 8)
        data.append(hint)
        let commandCount = duplicates ? 2 : 1
        let commandBlockBytes = 72 + commandCount * 16
        let finalHintOffset = UInt32(data.count - hint.count + commandBlockBytes)
        var block = linkeditSegment(offset: finalHintOffset, bytes: UInt32(hint.count))
        block.append(optimizationHintCommand(offset: finalHintOffset, bytes: UInt32(hint.count)))
        if duplicates { block.append(optimizationHintCommand(offset: finalHintOffset, bytes: UInt32(hint.count))) }
        return adding(block, to: data)
    }
    static func invalidRelocations(filetype: UInt32, installName: String = "") -> Data {
        var data = image(filetype: filetype, installName: installName)
        patch(&data, 160, .max); patch(&data, 164, .max)
        return data
    }
    static func dylibCommand(_ command: UInt32, _ path: String) -> Data {
        var text = Data(path.utf8); text.append(0)
        let size = (24 + text.count + 7) & ~7
        var data = u32(command) + u32(UInt32(size)) + u32(24) + u32(0) + u32(0x10000) + u32(0x10000)
        data.append(text); data.append(Data(repeating: 0, count: size - data.count)); return data
    }
    static func classicDyldInfoCommand() -> Data {
        var data = u32(0x80000022) + u32(48)
        data.append(Data(repeating: 0, count: 40))
        return data
    }
    static func chainedFixupsCommand(offset: UInt32, bytes: UInt32) -> Data {
        [UInt32(0x80000034), 16, offset, bytes].reduce(into: Data()) { $0.append(u32($1)) }
    }
    // Thin arm64, actual bounded LC_SEGMENT_64 + section_64 + ARM64 payload.
    // Dylibs also have the sole libSystem dependency and matching @rpath ID.
    static func image(filetype: UInt32, installName: String = "", includesObjC: Bool = false,
                      arm64e: Bool = false) -> Data {
        let payload = Data([0xc0, 0x03, 0x5f, 0xd6, 0x1f, 0x20, 0x03, 0xd5])
        let extra: Data
        if filetype == 6 {
            let objc = includesObjC ? dylibCommand(0xc, "/usr/lib/libobjc.A.dylib") : Data()
            extra = dylibCommand(0xc, "/usr/lib/libSystem.B.dylib") + objc + dylibCommand(0xd, installName)
        } else { extra = Data() }
        // Xcode ld64 emits classic dyld info for arm64 and chained fixups for arm64e.
        let dyldInfo = filetype == 6 && !arm64e ? classicDyldInfoCommand() : Data()
        let chained = filetype == 6 && arm64e ? chainedFixupsCommand(offset: 0, bytes: 8) : Data()
        let commandBytes = 152 + extra.count + dyldInfo.count + chained.count + (filetype == 6 ? 24 : 0)
        let offset = UInt32(32 + commandBytes)
        var segment = u32(0x19) + u32(152) + name(filetype == 1 ? "" : "__TEXT")
        segment.append(u64(0)); segment.append(u64(UInt64(payload.count)))
        segment.append(u64(UInt64(offset))); segment.append(u64(UInt64(payload.count)))
        segment.append(u32(7)); segment.append(u32(5)); segment.append(u32(1)); segment.append(u32(0))
        var section = name("__text") + name("__TEXT") + u64(0) + u64(UInt64(payload.count))
        for value in [offset, 2, 0, 0, 0x80000400, 0, 0, 0] { section.append(u32(value)) }
        segment.append(section)
        var data = Data()
        for value in [0xfeedfacf, 0x0100000c, arm64e ? 0x80000002 : 0, filetype,
                      filetype == 6 ? (includesObjC ? 6 : 5) : 1,
                      UInt32(commandBytes), filetype == 6 ? 0x85 : 0, 0] { data.append(u32(value)) }
        data.append(segment); data.append(extra); data.append(dyldInfo)
        if filetype == 6 && arm64e { data.append(chainedFixupsCommand(offset: offset, bytes: 8)) }
        if filetype == 6 { data.append(encryptionCommand(offset: offset, bytes: UInt32(payload.count))) }
        data.append(payload); return data
    }
}

enum Outcome: Equatable, Sendable { case ok, diagnostics, internalError, malformed, symlink, assertion, invalidRelocations, encrypted, downgraded }
struct BridgeSnapshot: Sendable {
    let calls: [[String]]
    let kinds: [String]
    let roots: [String]
    let capabilities: Int
    let samples: Int
    let stubs: Int
    let objcStubs: Int
    let copiedStub: Data?
}
final class FakeBridge: EmbeddedAdapterBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var compileOutcomes: [Outcome]
    private var linkOutcomes: [Outcome]
    private var memory: [UInt64]
    private var sampleIndex = 0
    private var calls: [[String]] = []
    private var kinds: [String] = []
    private var roots: [String] = []
    private var capabilityCalls = 0
    private var stubCalls = 0
    private var objcStubCalls = 0
    private var copiedStub: Data?
    private let cancelAfterCompile: EmbeddedAdapterCancellation?
    private let cancelAtSample: (Int, EmbeddedAdapterCancellation)?
    static let mib: UInt64 = 1024 * 1024
    static let stub = Data(repeating: 0x41, count: 1024)
    static let objcStub = Data(repeating: 0x42, count: 1024)
    init(compile: [Outcome] = [], link: [Outcome] = [], memory: [UInt64] = [128 * FakeBridge.mib],
         cancelAfterCompile: EmbeddedAdapterCancellation? = nil,
         cancelAtSample: (Int, EmbeddedAdapterCancellation)? = nil) {
        self.compileOutcomes = compile; self.linkOutcomes = link; self.memory = memory
        self.cancelAfterCompile = cancelAfterCompile; self.cancelAtSample = cancelAtSample
    }
    func capability() -> [String: String] {
        lock.lock(); capabilityCalls += 1; lock.unlock()
        return ["compiler_linked": "yes", "verification": "passed", "resource_headers": "present",
                "sdk": "present", "state": "ready", "host_architecture": "arm64"]
    }
    func residentBytes() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let value = memory[min(sampleIndex, memory.count - 1)]; sampleIndex += 1
        if let (sample, token) = cancelAtSample, sampleIndex == sample { token.cancel() }
        return value
    }
    func resetMemory(_ values: [UInt64]) { lock.lock(); memory = values; sampleIndex = 0; lock.unlock() }
    func verifiedLibSystemStub() throws -> Data { lock.lock(); stubCalls += 1; lock.unlock(); return Self.stub }
    func verifiedObjCRuntimeStub() throws -> Data { lock.lock(); objcStubCalls += 1; lock.unlock(); return Self.objcStub }
    func snapshot() -> BridgeSnapshot {
        lock.lock(); defer { lock.unlock() }
        return BridgeSnapshot(calls: calls, kinds: kinds, roots: roots, capabilities: capabilityCalls,
                              samples: sampleIndex, stubs: stubCalls, objcStubs: objcStubCalls, copiedStub: copiedStub)
    }
    func compile(_ arguments: [String]) -> EmbeddedAdapterCall {
        let result = invoke(arguments, linking: false); cancelAfterCompile?.cancel(); return result
    }
    func link(_ arguments: [String]) -> EmbeddedAdapterCall { invoke(arguments, linking: true) }
    private func invoke(_ arguments: [String], linking: Bool) -> EmbeddedAdapterCall {
        guard let index = arguments.firstIndex(of: "-o"), index + 1 < arguments.count else {
            return EmbeddedAdapterCall(status: 3, stdout: "", stderr: "fake received no owned output")
        }
        let output = URL(fileURLWithPath: arguments[index + 1])
        lock.lock()
        calls.append(arguments); kinds.append(linking ? "link" : "compile")
        roots.append(output.deletingLastPathComponent().path)
        let outcome: Outcome
        if linking { outcome = linkOutcomes.isEmpty ? .ok : linkOutcomes.removeFirst() }
        else { outcome = compileOutcomes.isEmpty ? .ok : compileOutcomes.removeFirst() }
        lock.unlock()
        if outcome == .diagnostics {
            return EmbeddedAdapterCall(status: 2, stdout: String(repeating: "o", count: 6000), stderr: String(repeating: "e", count: 6000))
        }
        if outcome == .internalError { return EmbeddedAdapterCall(status: 3, stdout: "", stderr: "internal failure") }
        if outcome == .assertion { return EmbeddedAdapterCall(status: 70, stdout: "", stderr: "internal assertion in fake linker") }
        do {
            if linking, let path = arguments.last {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                lock.lock(); copiedStub = data; lock.unlock()
            }
            switch outcome {
            case .encrypted:
                let install = arguments.firstIndex(of: "-install_name").map { arguments[$0 + 1] } ?? ""
                var data = MachOFixture.image(filetype: 6, installName: install)
                let command = MachOFixture.commandOffset(0x2c, in: data)
                MachOFixture.patch(&data, command + 16, 1)
                try data.write(to: output)
            case .invalidRelocations:
                let install = arguments.firstIndex(of: "-install_name").map { arguments[$0 + 1] } ?? ""
                try MachOFixture.invalidRelocations(filetype: linking ? 6 : 1, installName: install).write(to: output)
            case .malformed: try Data([0, 1, 2, 3]).write(to: output)
            case .symlink: try FileManager.default.createSymbolicLink(at: output, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
            default:
                let install = arguments.firstIndex(of: "-install_name").map { arguments[$0 + 1] } ?? ""
                let hasObjC = linking && arguments.contains { $0.hasSuffix("/libobjc.A.tbd") }
                let isArm64e = linking ? arguments.contains("arm64e") : arguments.contains("arm64e-apple-ios15.0")
                // Synthetic test fixtures only: the production adapter must
                // actually compile/link each architecture, never patch headers.
                let data = MachOFixture.image(filetype: linking ? 6 : 1, installName: install,
                                              includesObjC: hasObjC,
                                              arm64e: isArm64e && outcome != .downgraded)
                try data.write(to: output)
            }
            return EmbeddedAdapterCall(status: 0, stdout: "fake output", stderr: "")
        } catch { return EmbeddedAdapterCall(status: 3, stdout: "", stderr: "fake fixture I/O: \(error)") }
    }
}

private struct ContractFailure: Error, CustomStringConvertible {
    let description: String
}

@main @MainActor
private struct AdapterContracts {
    private static var checks = 0
    private static let sources = ["answer.c": "int answer(void) { return 42; }\n"]
    private static let operations: [EmbeddedToolchainOperation] = [
        .compile(source: "answer.c", output: "answer.o", language: .c),
        .link(objects: ["answer.o"], output: "libanswer.dylib", installName: "@rpath/libanswer.dylib")
    ]
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw ContractFailure(description: message) }
    }
    private static func cleanup(_ result: EmbeddedAdapterResult, _ fake: FakeBridge) throws {
        try require(result.temporaryOutputsRemoved, "cleanup flag must be true: \(result.reason)")
        try require(!result.providerExecutable && !result.outputExecutionAttempted, "metadata must never claim provider/output execution")
        for root in Set(fake.snapshot().roots) {
            try require(!FileManager.default.fileExists(atPath: root), "private run directory leaked: \(root)")
        }
        if result.state != "success" { try require(result.artifacts.isEmpty, "failed/cancelled result exposed partial artifact metadata") }
    }
    private static func run(_ adapter: EmbeddedToolchainExecutionAdapter) async -> EmbeddedAdapterResult {
        await adapter.execute(sources: sources, operations: operations)
    }
    private static func tempRoots() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("minis-adapter-") })
    }
    static func main() async {
        do { try await runContracts() }
        catch {
            FileHandle.standardError.write(Data("FAIL: actual Swift project contracts: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runContracts() async throws {
        let before = try tempRoots()
        guard ProcessInfo.processInfo.arguments.count == 3 else { throw ContractFailure(description: "real-linker fixture path and contract output directory required") }
        let real = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[1]))
        try require(real.count == 49336 && EmbeddedAdapterArtifact.digest(real) == "f7858c08290826dd443b3981e85bb7d908a2318f53a9c61530de12b9fbc33d4a", "real-linker fixture changed")
        _ = try EmbeddedAdapterArtifact.inspect(real, name: "probe.dylib", filetype: 6)
        checks += 1
        print("PASS: actual Clang/LLD-linked iOS dylib bytes inspected by production Swift (not native ld64/device evidence)")
        let nativeA = EmbeddedToolchainExecutionAdapter(bridge: EmbeddedNativeAdapterBridge())
        let nativeB = EmbeddedToolchainExecutionAdapter(bridge: EmbeddedNativeAdapterBridge())
        try require(nativeA.processScopeID == nativeB.processScopeID &&
                    nativeA.processScopeID == EmbeddedToolchainExecutionAdapter.shared.processScopeID,
                    "new native adapters must share the entire process queue/budget/poison state")
        try malformedMachO(); print("PASS: Mach-O relocation, command and linkedit range mutations")
        try await encryptionPolicy(); print("PASS: unencrypted metadata accepted; encrypted/unsafe output rejected and poisoned")
        try await successAndArguments(); print("PASS: success, metadata, cleanup and fixed argv")
        try await cancellation(); print("PASS: pre-cancel and cancellation during compile")
        try await diagnosticsRecovery(); print("PASS: compile/link diagnostics recover on the same instance")
        try await permanentPoison(); print("PASS: status 3, malformed and symlink outputs permanently poison")
        try await memoryBudgets(); print("PASS: unknown RSS and absolute/lifetime RSS limits")
        try await lifetimeLinks(); print("PASS: three-link lifetime budget across requests")
        try await rejectedInputs(); print("PASS: source, filename, language and operation rejection matrix")
        try await projectSnapshotToPublishedDylib(); print("PASS: multi-file project request, verified execution, atomic project publication, cleanup and no output execution")
        checks += try await RestrictedExecutionContracts.run()
        checks += try ProjectPublisherContracts.run()
        checks += try await PackageContracts.run(outputDirectory: ProcessInfo.processInfo.arguments[2])
        let after = try tempRoots()
        try require(after == before, "a request leaked an unrecorded private run directory")
        print("PASS: \(checks) real Swift adapter contract assertions; fake bridge only, no native LLVM or output execution.")
    }
    private static func projectSnapshotToPublishedDylib() async throws {
        let files = [
            "src/main.c": "#include \"value.h\"\nint main_value(void) { return value(); }\n",
            "src/value.h": "int value(void) { return 7; }\n"
        ]
        let snapshot = try EmbeddedToolchainProjectSnapshotBuilder.build(files: files, entrySources: ["src/main.c"])
        let plan = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "project.dylib")
        let request = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: plan)
        let fake = FakeBridge()
        let executor = EmbeddedToolchainRestrictedExecutor(adapter: EmbeddedToolchainExecutionAdapter(bridge: fake))
        let report = await executor.execute(request, captureVerifiedDylib: true)
        try require(report.passed && !report.outputFilesPublished && !report.outputExecutionAttempted &&
                    !report.providerExecutable, "verified execution report flags")
        guard let bytes = report.dylibData, let inspected = report.verifiedArtifact else {
            throw ContractFailure(description: "capturing executor must return inspected dylib bytes and metadata")
        }
        try require(inspected.name == request.outputName && inspected.bytes == bytes.count &&
                    inspected.sha256 == EmbeddedAdapterArtifact.digest(bytes), "captured dylib metadata binding")
        try cleanup(report.adapter, fake)

        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("minis-project-publish-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let published = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(
            bytes, named: request.outputName, projectRoot: root)
        let output = root.appendingPathComponent(published.relativePath)
        let onDisk = try Data(contentsOf: output)
        try require(onDisk == bytes && published.bytes == bytes.count &&
                    published.sha256 == inspected.sha256 && published.filetype == 6 &&
                    published.relativePath == "build/minis-embedded/project.dylib",
                    "atomic user-selected project publication metadata")
        try require(!report.outputFilesPublished, "execution report remains pre-publication evidence only")
        let diagnostic = try JSONEncoder().encode(report.adapter)
        let diagnosticText = String(data: diagnostic, encoding: .utf8) ?? ""
        try require(!diagnosticText.contains("capturedDylibData"), "binary output must not be serialized into diagnostics")
    }

    private static func malformedMachO() throws {
        let object = MachOFixture.image(filetype: 1)
        var outsideSegment = object
        MachOFixture.patch(&outsideSegment, 152, 0) // __text section offset must belong to its segment
        let badDysym = MachOFixture.adding(MachOFixture.u32(0xb) + MachOFixture.u32(8), to: object)
        var badVersionCommand = MachOFixture.u32(0x32) + MachOFixture.u32(24)
        for value in [UInt32(2), 0x000f0000, 0x00100000, UInt32.max] { badVersionCommand.append(MachOFixture.u32(value)) }
        let badVersion = MachOFixture.adding(badVersionCommand, to: object)
        let unknown = MachOFixture.adding(MachOFixture.u32(0xdeadbeef) + MachOFixture.u32(8), to: object)
        let dylib = MachOFixture.image(filetype: 6, installName: "@rpath/bad.dylib")
        let rootlessInstallName = "/var/jb/Library/MobileSubstrate/DynamicLibraries/bad.dylib"
        let rootlessDylib = MachOFixture.image(filetype: 6, installName: rootlessInstallName)
        _ = try EmbeddedAdapterArtifact.inspect(rootlessDylib, name: "bad.dylib", filetype: 6,
            expectedInstallName: rootlessInstallName)
        do {
            _ = try EmbeddedAdapterArtifact.inspect(rootlessDylib, name: "bad.dylib", filetype: 6,
                expectedInstallName: "/var/jb/Library/MobileSubstrate/DynamicLibraries/Other/bad.dylib")
            throw ContractFailure(description: "rootless install ID differing from its declared path was accepted")
        } catch EmbeddedAdapterError.poisoned(let reason) {
            try require(reason.contains("dependency_or_install_name_mismatch"), "wrong absolute install ID rejection: \(reason)")
        }
        var modern = MachOFixture.adding(MachOFixture.u32(0x2a) + MachOFixture.u32(16) + MachOFixture.u64(0), to: dylib)
        for command in [UInt32(0x80000033), 0x80000034] {
            modern = MachOFixture.adding(MachOFixture.u32(command) + MachOFixture.u32(16) + MachOFixture.u64(0), to: modern)
        }
        _ = try EmbeddedAdapterArtifact.inspect(modern, name: "bad.dylib", filetype: 6)
        do {
            _ = try EmbeddedAdapterArtifact.inspect(modern, name: "bad.dylib", filetype: 6,
                                                     fixupPolicy: .classic)
            throw ContractFailure(description: "chained-fixup dylib passed the classic-fixup policy")
        } catch EmbeddedAdapterError.poisoned(let reason) {
            try require(reason.contains("classic_dyld_info_required_and_chained_fixups_forbidden"),
                        "wrong chained-fixup policy rejection: \(reason)")
        }
        let xcodeArm64e = MachOFixture.image(filetype: 6, installName: "@rpath/bad.dylib", arm64e: true)
        _ = try EmbeddedAdapterArtifact.inspect(xcodeArm64e, name: "bad.dylib", filetype: 6,
                                                 architecture: .arm64e, fixupPolicy: .xcodeCompatible)
        var classicArm64e = MachOFixture.image(filetype: 6, installName: "@rpath/bad.dylib")
        MachOFixture.patch(&classicArm64e, 8, 0x80000002)
        do {
            _ = try EmbeddedAdapterArtifact.inspect(classicArm64e, name: "bad.dylib", filetype: 6,
                                                     architecture: .arm64e, fixupPolicy: .xcodeCompatible)
            throw ContractFailure(description: "classic arm64e dylib passed the Xcode-compatible policy")
        } catch EmbeddedAdapterError.poisoned(let reason) {
            try require(reason.contains("arm64e_chained_fixups_required"),
                        "wrong arm64e classic rejection: \(reason)")
        }
        var chainedArm64 = xcodeArm64e
        MachOFixture.patch(&chainedArm64, 8, 0)
        do {
            _ = try EmbeddedAdapterArtifact.inspect(chainedArm64, name: "bad.dylib", filetype: 6,
                                                     fixupPolicy: .xcodeCompatible)
            throw ContractFailure(description: "chained arm64 dylib passed the Xcode-compatible policy")
        } catch EmbeddedAdapterError.poisoned(let reason) {
            try require(reason.contains("arm64_classic_dyld_info_required"),
                        "wrong arm64 chained rejection: \(reason)")
        }
        checks += 1
        let badLinkedit = MachOFixture.adding(MachOFixture.u32(0x26) + MachOFixture.u32(16) +
                                            MachOFixture.u32(.max) + MachOFixture.u32(.max), to: dylib)
        let objectHint = MachOFixture.objectWithOptimizationHint()
        _ = try EmbeddedAdapterArtifact.inspect(objectHint, name: "unit.o", filetype: 1)
        checks += 1
        let objectHintCommand = MachOFixture.commandOffset(0x2e, in: objectHint)
        var objectHintOutsideSection = objectHint
        var objectHintOverSymbolTable = objectHint
        let symbolTableCommand = MachOFixture.commandOffset(0x2, in: objectHint)
        let symbolTableOffset = MachOFixture.read32(objectHint, symbolTableCommand + 8)
        MachOFixture.patch(&objectHintOverSymbolTable, objectHintCommand + 8, symbolTableOffset)
        do {
            _ = try EmbeddedAdapterArtifact.inspect(objectHintOverSymbolTable, name: "unit.o", filetype: 1)
            throw ContractFailure(description: "object optimization hint overlapping symbol table was accepted")
        } catch EmbeddedAdapterError.poisoned(let reason) {
            try require(reason.contains("optimization_hint_overlaps_object_data"), "wrong object hint overlap rejection: \\(reason)")
        }
        var objectHintOutsideFile = objectHint
        MachOFixture.patch(&objectHintOutsideFile, objectHintCommand + 8, UInt32(objectHint.count - 2))
        MachOFixture.patch(&objectHintOutsideFile, objectHintCommand + 12, 8)
        do {
            _ = try EmbeddedAdapterArtifact.inspect(objectHintOutsideFile, name: "unit.o", filetype: 1)
            throw ContractFailure(description: "object optimization hint outside file was accepted")
        } catch EmbeddedAdapterError.poisoned(let reason) {
            try require(reason.contains("optimization_hint_range_outside_payload"), "wrong object hint file-range rejection: \\(reason)")
        }
        let hint = MachOFixture.imageWithOptimizationHint(installName: "@rpath/bad.dylib")
        _ = try EmbeddedAdapterArtifact.inspect(hint, name: "bad.dylib", filetype: 6)
        checks += 1
        let hintCommand = MachOFixture.commandOffset(0x2e, in: hint)
        var badHintRange = hint
        MachOFixture.patch(&badHintRange, hintCommand + 8, .max)
        var outsideLinkedit = hint
        let textPayloadOffset = UInt32(32 + MachOFixture.read32(hint, 20))
        MachOFixture.patch(&outsideLinkedit, hintCommand + 8, textPayloadOffset)
        let duplicateHint = MachOFixture.imageWithOptimizationHint(installName: "@rpath/bad.dylib", duplicates: true)
        for (data, rule) in [(badHintRange, "optimization_hint_range_outside_payload"),
                             (outsideLinkedit, "optimization_hint_outside_linkedit"),
                             (duplicateHint, "optimization_hint_command_size_or_duplicate")] {
            do {
                _ = try EmbeddedAdapterArtifact.inspect(data, name: "bad.dylib", filetype: 6)
                throw ContractFailure(description: "unsafe optimization hint accepted")
            } catch EmbeddedAdapterError.poisoned(let reason) {
                try require(reason.contains(rule), "wrong optimization hint rejection: \(reason)")
            }
        }
        for (data, type) in [(MachOFixture.invalidRelocations(filetype: 1), UInt32(1)),
                             (outsideSegment, 1), (badDysym, 1), (badVersion, 1), (unknown, 1), (badLinkedit, 6)] {
            do {
                _ = try EmbeddedAdapterArtifact.inspect(data, name: "bad.dylib", filetype: type)
                throw ContractFailure(description: "malformed Mach-O variant was accepted")
            } catch EmbeddedAdapterError.poisoned(_) { checks += 1 }
        }
    }
    private static func encryptionPolicy() async throws {
        let image = MachOFixture.image(filetype: 6, installName: "@rpath/probe.dylib")
        let encryption = MachOFixture.commandOffset(0x2c, in: image)
        _ = try EmbeddedAdapterArtifact.inspect(image, name: "probe.dylib", filetype: 6)
        checks += 1
        var encrypted = image; MachOFixture.patch(&encrypted, encryption + 16, 1)
        var padded = image; MachOFixture.patch(&padded, encryption + 20, 1)
        var badOffset = image; MachOFixture.patch(&badOffset, encryption + 8, .max)
        var badSize = image; MachOFixture.patch(&badSize, encryption + 12, .max)
        var inHeader = image; MachOFixture.patch(&inHeader, encryption + 8, 0)
        var short = image; MachOFixture.patch(&short, encryption + 4, 16)
        var long = image; MachOFixture.patch(&long, encryption + 4, 32)
        var beyondText = image
        beyondText.append(Data(repeating: 0, count: 8)) // still inside file, outside the __TEXT file range
        MachOFixture.patch(&beyondText, encryption + 12, 16) // extends beyond __TEXT, still within file
        let originalEncryptionOffset = UInt32(image[encryption + 8]) |
            UInt32(image[encryption + 9]) << 8 | UInt32(image[encryption + 10]) << 16 |
            UInt32(image[encryption + 11]) << 24
        let duplicate = MachOFixture.adding(
            MachOFixture.encryptionCommand(offset: originalEncryptionOffset + 24, bytes: 8), to: image)
        let inObject = MachOFixture.adding(MachOFixture.encryptionCommand(offset: 208, bytes: 8), to: MachOFixture.image(filetype: 1))
        for (data, type, rule) in [(encrypted, UInt32(6), "encrypted_output_cryptid_nonzero"),
            (padded, 6, "encryption_reserved_padding_nonzero"), (badOffset, 6, "encryption_range_outside_payload"),
            (badSize, 6, "encryption_range_outside_payload"), (inHeader, 6, "encryption_range_outside_payload"),
            (short, 6, "encryption_command_size_or_duplicate"),
            (long, 6, "encryption_command_size_or_duplicate"),
            (beyondText, 6, "encryption_range_outside_text_segment"), (duplicate, 6, "encryption_command_size_or_duplicate"),
            (inObject, 1, "unsupported_load_command=0x2c")] {
            do {
                _ = try EmbeddedAdapterArtifact.inspect(data, name: "probe.dylib", filetype: type)
                throw ContractFailure(description: "encryption metadata mutation accepted: \(rule)")
            } catch EmbeddedAdapterError.poisoned(let reason) {
                try require(reason.contains(rule) && reason.contains("check_line="), "wrong encryption rejection rule: \(reason)")
            }
        }
        let fake = FakeBridge(link: [.encrypted])
        let adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
        let failed = await run(adapter)
        try require(failed.state == "poisoned" && failed.reason.contains("encrypted_output_cryptid_nonzero"),
                    "encrypted linker output must poison rather than become a successful artifact")
        try cleanup(failed, fake)
        let calls = fake.snapshot().calls.count
        let retry = await run(adapter)
        try require(retry.state == "poisoned" && fake.snapshot().calls.count == calls,
                    "encrypted-output poison must persist across requests")
    }
    private static func successAndArguments() async throws {
        let fake = FakeBridge(), adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
        let result = await run(adapter), snapshot = fake.snapshot()
        try require(result.passed && result.state == "success", "success fixture rejected: \(result.state) \(result.reason)")
        try require(result.steps.map(\.status) == [0, 0] && snapshot.kinds == ["compile", "link"], "expected one compile and one link")
        try require(result.processLinkCount == 1 && result.residentSamplesBytes.count == 5, "link/sample metadata incorrect")
        try require(result.artifacts.count == 2, "expected object and dylib inspection metadata")
        for artifact in result.artifacts {
            let type: UInt32 = artifact.name == "answer.o" ? 1 : 6
            let bytes = MachOFixture.image(filetype: type, installName: "@rpath/" + artifact.name)
            try require(artifact.bytes == bytes.count && artifact.filetype == type && artifact.architecture == "arm64", "incorrect Mach-O metadata")
            try require(artifact.sha256 == EmbeddedAdapterArtifact.digest(bytes) && artifact.sha256.count == 64, "incorrect SHA-256 metadata")
            try require(!artifact.name.contains("/"), "artifact metadata must not expose an available file path")
        }
        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(EmbeddedAdapterResult.self, from: encoded)
        try require(decoded.passed && decoded.artifacts.count == 2, "Codable result round trip failed")
        let root = URL(fileURLWithPath: snapshot.roots[0])
        let cc = snapshot.calls[0], ld = snapshot.calls[1]
        let compileOutput = cc[cc.firstIndex(of: "-o")! + 1]
        let linkOutput = ld[ld.firstIndex(of: "-o")! + 1]
        try require(URL(fileURLWithPath: compileOutput).deletingLastPathComponent().path == root.path &&
                    URL(fileURLWithPath: linkOutput).deletingLastPathComponent().path == root.path &&
                    URL(fileURLWithPath: compileOutput).lastPathComponent.hasPrefix("partial-") &&
                    URL(fileURLWithPath: linkOutput).lastPathComponent.hasPrefix("partial-") && compileOutput != linkOutput,
                    "outputs must be distinct private partial paths")
        try require(cc == ["-triple", "arm64-apple-ios15.0", "-target-cpu", "apple-a7", "-emit-obj", "-ffreestanding",
                           "-std=c11", "-O1", "-nostdsysteminc", "-nobuiltininc", "-ferror-limit", "16",
                           "-o", compileOutput, "-x", "c", root.appendingPathComponent("answer.c").path], "compile argv was not the fixed reviewed argv")
        try require(ld == ["-arch", "arm64", "-no_fixup_chains", "-dylib", "-platform_version", "ios", "15.0", "16.5",
                           "-install_name", "@rpath/libanswer.dylib", "-o", linkOutput,
                           root.appendingPathComponent("answer.o").path, root.appendingPathComponent("libSystem.B.tbd").path],
                    "link argv was not the fixed reviewed argv")
        try require(snapshot.stubs == 1 && snapshot.copiedStub == FakeBridge.stub, "verified stub must be copied into the private run")
        try cleanup(result, fake)
        let objcFake = FakeBridge()
        let objcAdapter = EmbeddedToolchainExecutionAdapter(bridge: objcFake)
        let objcResult = await objcAdapter.execute(
            sources: ["answer.m": "int answer(void) { return 42; }\n"],
            operations: [.compile(source: "answer.m", output: "answer.o", language: .objectiveC),
                         .link(objects: ["answer.o"], output: "libanswer.dylib", installName: "@rpath/libanswer.dylib")])
        let objcSnapshot = objcFake.snapshot()
        try require(objcResult.passed && objcSnapshot.calls[0].contains("objective-c") &&
                    objcSnapshot.calls[0].contains("-fobjc-arc"), "Objective-C structured language was not translated")
        try require(objcSnapshot.objcStubs == 1 && objcSnapshot.calls[1].last?.hasSuffix("libobjc.A.tbd") == true,
                    "Objective-C project must add the pinned libobjc runtime stub to its link")
        try cleanup(objcResult, objcFake)
    }
    private static func cancellation() async throws {
        let token = EmbeddedAdapterCancellation(); token.cancel()
        let fake = FakeBridge(), adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
        let pre = await adapter.execute(sources: sources, operations: operations, cancellation: token)
        let snapshot = fake.snapshot()
        try require(pre.state == "cancelled" && snapshot.calls.isEmpty && snapshot.capabilities == 0 && snapshot.samples == 0 && snapshot.stubs == 0,
                    "pre-cancel must make zero bridge calls")
        try cleanup(pre, fake)
        let duringToken = EmbeddedAdapterCancellation()
        let duringFake = FakeBridge(cancelAfterCompile: duringToken)
        let during = await EmbeddedToolchainExecutionAdapter(bridge: duringFake).execute(
            sources: sources, operations: operations, cancellation: duringToken)
        try require(during.state == "cancelled" && duringFake.snapshot().kinds == ["compile"] &&
                    during.processLinkCount == 0 && duringFake.snapshot().stubs == 0, "cancel during compile must not link")
        try cleanup(during, duringFake)
        let lateToken = EmbeddedAdapterCancellation()
        let lateFake = FakeBridge(cancelAtSample: (3, lateToken))
        let late = await EmbeddedToolchainExecutionAdapter(bridge: lateFake).execute(
            sources: sources, operations: [operations[0]], cancellation: lateToken)
        try require(late.state == "cancelled" && !late.passed && late.artifacts.isEmpty,
                    "cancellation at final completion sample must not return success")
        try cleanup(late, lateFake)
    }
    private static func diagnosticsRecovery() async throws {
        for linking in [false, true] {
            let fake = FakeBridge(compile: linking ? [] : [.diagnostics], link: linking ? [.diagnostics] : [])
            let adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
            let failed = await run(adapter)
            try require(failed.state == "diagnostics" && !failed.passed, "status 2 must be diagnostics, not success/poison")
            try require(failed.steps.last?.stdout.count == 4096 && failed.steps.last?.stderr.count == 4096, "diagnostic text must be bounded")
            try require(failed.processLinkCount == (linking ? 1 : 0), "diagnostic link attempt was not counted")
            try cleanup(failed, fake)
            let recovered = await run(adapter)
            try require(recovered.passed && recovered.processLinkCount == (linking ? 2 : 1), "diagnostics must allow same-instance recovery")
            try cleanup(recovered, fake)
        }
    }
    private static func permanentPoison() async throws {
        for outcome in [Outcome.internalError, .malformed, .symlink, .assertion, .invalidRelocations] {
            for linking in [false, true] {
                let fake = FakeBridge(compile: linking ? [] : [outcome], link: linking ? [outcome] : [])
                let adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
                let failed = await run(adapter)
                try require(failed.state == "poisoned" && !failed.reason.isEmpty, "\(outcome) must poison the adapter")
                try cleanup(failed, fake)
                let calls = fake.snapshot().calls.count
                let retry = await run(adapter)
                try require(retry.state == "poisoned" && fake.snapshot().calls.count == calls &&
                            retry.reason == failed.reason, "poison must persist and prevent new bridge calls")
                try require(retry.processLinkCount == (linking ? 1 : 0), "poisoned link attempt count incorrect")
                try cleanup(retry, fake)
            }
        }
    }
    private static func memoryBudgets() async throws {
        let mib = FakeBridge.mib
        for samples in [[UInt64(0)], [128 * mib, 0]] {
            let fake = FakeBridge(memory: samples), adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
            let unknown = await run(adapter)
            try require(unknown.state == "unavailable" && unknown.processLinkCount == 0, "unknown RSS must stop before linking")
            try require(fake.snapshot().calls.count == (samples.count == 1 ? 0 : 1), "unknown RSS call boundary incorrect")
            try cleanup(unknown, fake)
            fake.resetMemory([128 * mib])
            let recovered = await run(adapter)
            try require(recovered.passed, "unknown RSS must not silently poison the adapter")
            try cleanup(recovered, fake)
        }
        // Current policy is strict: reaching (not just exceeding) either cap
        // exhausts the adapter; test both the boundary and an over-budget value.
        for samples in [[448 * mib], [449 * mib], [128 * mib, 192 * mib], [128 * mib, 193 * mib]] {
            let fake = FakeBridge(memory: samples), adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
            let exceeded = await run(adapter)
            try require(exceeded.state == "budget_exceeded" && exceeded.processLinkCount == 0, "RSS cap must stop without linking")
            try require(fake.snapshot().calls.count == (samples.count == 1 ? 0 : 1), "RSS cap did not stop at the expected boundary")
            try cleanup(exceeded, fake)
            let calls = fake.snapshot().calls.count
            fake.resetMemory([128 * mib])
            let retry = await run(adapter)
            try require(retry.state == "budget_exceeded" && fake.snapshot().calls.count == calls, "RSS exhaustion must persist")
            try cleanup(retry, fake)
        }
        let fake = FakeBridge(memory: [128 * mib, 191 * mib]), adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
        let allowed = await run(adapter)
        try require(allowed.passed, "63 MiB growth within absolute cap should pass")
        try cleanup(allowed, fake)
        let count = fake.snapshot().calls.count
        fake.resetMemory([193 * mib])
        let later = await run(adapter)
        try require(later.state == "budget_exceeded" && fake.snapshot().calls.count == count,
                    "lifetime RSS baseline must persist across requests, not reset per run")
        try cleanup(later, fake)
    }
    private static func lifetimeLinks() async throws {
        let fake = FakeBridge(), adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
        for index in 1...3 {
            let result = await run(adapter)
            try require(result.passed && result.processLinkCount == index, "lifetime link \(index) should succeed")
            try cleanup(result, fake)
        }
        let calls = fake.snapshot().calls.count
        let fourth = await run(adapter)
        try require(fourth.state == "budget_exceeded" && fourth.processLinkCount == 3 &&
                    fake.snapshot().calls.count == calls && fake.snapshot().kinds.filter { $0 == "link" }.count == 3,
                    "fourth request must stop before any bridge call")
        try cleanup(fourth, fake)
    }
    private static func reject(_ label: String, sources input: [String: String], operations ops: [EmbeddedToolchainOperation]) async throws {
        let fake = FakeBridge()
        let result = await EmbeddedToolchainExecutionAdapter(bridge: fake).execute(sources: input, operations: ops)
        try require(result.state == "rejected" && !result.passed, "\(label) was not rejected: \(result.state) \(result.reason)")
        try require(fake.snapshot().calls.isEmpty && fake.snapshot().stubs == 0 && result.processLinkCount == 0,
                    "\(label) reached compile/link or copied a library")
        try cleanup(result, fake)
    }
    private static func rejectedInputs() async throws {
        let badSources = [
            "#include <stdio.h>\n", "%:include <stdio.h>\n", "??=include <stdio.h>\n",
            "int answer(void) { \\\nreturn 42; }\n", "asm(\".incbin /tmp/secret\");\n", "__asm__(\"nop\");\n",
            "#pragma clang module import X\n", "_Pragma(\"clang module import X\")\n", "__pragma(comment(lib, X))\n",
            "#import <Foundation/Foundation.h>\n", "@import Foundation;\n", "int café;\n", "", String(repeating: "a", count: 128 * 1024 + 1)
        ]
        for (index, source) in badSources.enumerated() {
            try await reject("source policy \(index)", sources: ["answer.c": source], operations: operations)
        }
        for name in ["../answer.c", "/answer.c", "nested/answer.c", "answer space.c", "-flag.c", "a..c",
                     "answer.c\0", "answer;id.c", "中文.c", "answer.C", "answer.cpp"] {
            try await reject("source name \(name.debugDescription)", sources: [name: sources["answer.c"]!],
                             operations: [.compile(source: name, output: "answer.o", language: .c)])
        }
        for output in ["../answer.o", "/answer.o", "nested/answer.o", "-o.o", "answer;id.o", "answer.dylib", "answer.c"] {
            try await reject("compile output \(output)", sources: sources,
                             operations: [.compile(source: "answer.c", output: output, language: .c)])
        }
        try await reject("C source with Objective-C language", sources: sources,
                         operations: [.compile(source: "answer.c", output: "answer.o", language: .objectiveC)])
        try await reject("Objective-C source with C language", sources: ["answer.m": sources["answer.c"]!],
                         operations: [.compile(source: "answer.m", output: "answer.o", language: .c)])
        try await reject("duplicate output", sources: sources, operations: [operations[0], operations[0]])
        try await reject("missing source", sources: sources,
                         operations: [.compile(source: "missing.c", output: "answer.o", language: .c)])
        for object in ["external.o", "../outside.o", "/tmp/foreign.o"] {
            try await reject("external object \(object)", sources: sources,
                             operations: [.link(objects: [object], output: "libanswer.dylib", installName: "@rpath/libanswer.dylib")])
        }
        try await reject("future object", sources: sources, operations: [operations[1], operations[0]])
        try await reject("duplicate object", sources: sources, operations: [operations[0],
            .link(objects: ["answer.o", "answer.o"], output: "libanswer.dylib", installName: "@rpath/libanswer.dylib")])
        for install in ["/tmp/libanswer.dylib", "@rpath/wrong.dylib", "@rpath/../libanswer.dylib",
                        "@loader_path/libanswer.dylib", "@rpath//libanswer.dylib", "@rpath/libanswer.dylib;id"] {
            try await reject("installName \(install)", sources: sources, operations: [operations[0],
                .link(objects: ["answer.o"], output: "libanswer.dylib", installName: install)])
        }
        try await reject("multiple links", sources: sources, operations: [operations[0], operations[1], operations[1]])
        try await reject("empty sources", sources: [:], operations: operations)
        try await reject("empty operations", sources: sources, operations: [])
        let fake = FakeBridge(), adapter = EmbeddedToolchainExecutionAdapter(bridge: fake)
        let previous = await adapter.execute(sources: sources, operations: [operations[0]])
        try require(previous.passed, "compile-only request must pass")
        try cleanup(previous, fake)
        let stale = await adapter.execute(sources: sources, operations: [operations[1]])
        try require(stale.state == "rejected" && fake.snapshot().calls.count == 1, "previous-request objects must not be reused")
        try cleanup(stale, fake)
    }
}
