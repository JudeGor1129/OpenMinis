// Standalone executable contracts for the real EmbeddedToolchainExecutionAdapter.
// OMToolchain below is a compile-only native stub; FakeBridge is the injected
// seam. Neither implements an adapter, compiles C, links LLVM or runs output.
import Foundation

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

private enum MachOFixture {
    static func u32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func u64(_ value: UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func name(_ value: String) -> Data { var d = Data(value.utf8); d.append(Data(repeating: 0, count: 16 - d.count)); return d }
    static func patch(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data.replaceSubrange(offset..<(offset + 4), with: u32(value))
    }
    static func adding(_ command: Data, to original: Data) -> Data {
        var data = original
        func read(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        let count = read(16), bytes = read(20), payload = Int(bytes) + 32
        data.insert(contentsOf: command, at: payload)
        patch(&data, 16, count + 1); patch(&data, 20, bytes + UInt32(command.count))
        patch(&data, 72, UInt32(payload + command.count)) // segment fileoff (low word)
        patch(&data, 152, UInt32(payload + command.count)) // section file offset
        return data
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
    // Thin arm64, actual bounded LC_SEGMENT_64 + section_64 + ARM64 payload.
    // Dylibs also have the sole libSystem dependency and matching @rpath ID.
    static func image(filetype: UInt32, installName: String = "") -> Data {
        let payload = Data([0xc0, 0x03, 0x5f, 0xd6, 0x1f, 0x20, 0x03, 0xd5])
        let extra = filetype == 6
            ? dylibCommand(0xc, "/usr/lib/libSystem.B.dylib") + dylibCommand(0xd, installName) : Data()
        let commandBytes = 152 + extra.count
        let offset = UInt32(32 + commandBytes)
        var segment = u32(0x19) + u32(152) + name(filetype == 1 ? "" : "__TEXT")
        segment.append(u64(0)); segment.append(u64(UInt64(payload.count)))
        segment.append(u64(UInt64(offset))); segment.append(u64(UInt64(payload.count)))
        segment.append(u32(7)); segment.append(u32(5)); segment.append(u32(1)); segment.append(u32(0))
        var section = name("__text") + name("__TEXT") + u64(0) + u64(UInt64(payload.count))
        for value in [offset, 2, 0, 0, 0x80000400, 0, 0, 0] { section.append(u32(value)) }
        segment.append(section)
        var data = Data()
        for value in [0xfeedfacf, 0x0100000c, 0, filetype, filetype == 6 ? 3 : 1,
                              UInt32(commandBytes), filetype == 6 ? 0x85 : 0, 0] { data.append(u32(value)) }
        data.append(segment); data.append(extra); data.append(payload); return data
    }
}

private enum Outcome: Equatable, Sendable { case ok, diagnostics, internalError, malformed, symlink, assertion, invalidRelocations }
private struct BridgeSnapshot: Sendable {
    let calls: [[String]]
    let kinds: [String]
    let roots: [String]
    let capabilities: Int
    let samples: Int
    let stubs: Int
    let copiedStub: Data?
}
private final class FakeBridge: EmbeddedAdapterBridge, @unchecked Sendable {
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
    private var copiedStub: Data?
    private let cancelAfterCompile: EmbeddedAdapterCancellation?
    private let cancelAtSample: (Int, EmbeddedAdapterCancellation)?
    static let mib: UInt64 = 1024 * 1024
    static let stub = Data(repeating: 0x41, count: 1024)
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
    func snapshot() -> BridgeSnapshot {
        lock.lock(); defer { lock.unlock() }
        return BridgeSnapshot(calls: calls, kinds: kinds, roots: roots, capabilities: capabilityCalls,
                              samples: sampleIndex, stubs: stubCalls, copiedStub: copiedStub)
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
            case .invalidRelocations:
                let install = arguments.firstIndex(of: "-install_name").map { arguments[$0 + 1] } ?? ""
                try MachOFixture.invalidRelocations(filetype: linking ? 6 : 1, installName: install).write(to: output)
            case .malformed: try Data([0, 1, 2, 3]).write(to: output)
            case .symlink: try FileManager.default.createSymbolicLink(at: output, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
            default:
                let install = arguments.firstIndex(of: "-install_name").map { arguments[$0 + 1] } ?? ""
                try MachOFixture.image(filetype: linking ? 6 : 1, installName: install).write(to: output)
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
    static func main() async throws {
        let before = try tempRoots()
        let nativeA = EmbeddedToolchainExecutionAdapter(bridge: EmbeddedNativeAdapterBridge())
        let nativeB = EmbeddedToolchainExecutionAdapter(bridge: EmbeddedNativeAdapterBridge())
        try require(nativeA.processScopeID == nativeB.processScopeID &&
                    nativeA.processScopeID == EmbeddedToolchainExecutionAdapter.shared.processScopeID,
                    "new native adapters must share the entire process queue/budget/poison state")
        try malformedMachO(); print("PASS: Mach-O relocation, command and linkedit range mutations")
        try await successAndArguments(); print("PASS: success, metadata, cleanup and fixed argv")
        try await cancellation(); print("PASS: pre-cancel and cancellation during compile")
        try await diagnosticsRecovery(); print("PASS: compile/link diagnostics recover on the same instance")
        try await permanentPoison(); print("PASS: status 3, malformed and symlink outputs permanently poison")
        try await memoryBudgets(); print("PASS: unknown RSS and absolute/lifetime RSS limits")
        try await lifetimeLinks(); print("PASS: three-link lifetime budget across requests")
        try await rejectedInputs(); print("PASS: source, filename, language and operation rejection matrix")
        let after = try tempRoots()
        try require(after == before, "a request leaked an unrecorded private run directory")
        print("PASS: \(checks) real Swift adapter contract assertions; fake bridge only, no native LLVM or output execution.")
    }
    private static func malformedMachO() throws {
        let object = MachOFixture.image(filetype: 1)
        var outsideSegment = object
        MachOFixture.patch(&outsideSegment, 72, 0)
        let badDysym = MachOFixture.adding(MachOFixture.u32(0xb) + MachOFixture.u32(8), to: object)
        var badVersionCommand = MachOFixture.u32(0x32) + MachOFixture.u32(24)
        for value in [UInt32(2), 0x000f0000, 0x00100000, UInt32.max] { badVersionCommand.append(MachOFixture.u32(value)) }
        let badVersion = MachOFixture.adding(badVersionCommand, to: object)
        let unknown = MachOFixture.adding(MachOFixture.u32(0xdeadbeef) + MachOFixture.u32(8), to: object)
        let dylib = MachOFixture.image(filetype: 6, installName: "@rpath/bad.dylib")
        var modern = MachOFixture.adding(MachOFixture.u32(0x2a) + MachOFixture.u32(16) + MachOFixture.u64(0), to: dylib)
        for command in [UInt32(0x80000033), 0x80000034] {
            modern = MachOFixture.adding(MachOFixture.u32(command) + MachOFixture.u32(16) + MachOFixture.u64(0), to: modern)
        }
        _ = try EmbeddedAdapterArtifact.inspect(modern, name: "bad.dylib", filetype: 6)
        checks += 1
        let badLinkedit = MachOFixture.adding(MachOFixture.u32(0x26) + MachOFixture.u32(16) +
                                            MachOFixture.u32(.max) + MachOFixture.u32(.max), to: dylib)
        for (data, type) in [(MachOFixture.invalidRelocations(filetype: 1), UInt32(1)),
                             (outsideSegment, 1), (badDysym, 1), (badVersion, 1), (unknown, 1), (badLinkedit, 6)] {
            do {
                _ = try EmbeddedAdapterArtifact.inspect(data, name: "bad.dylib", filetype: type)
                throw ContractFailure(description: "malformed Mach-O variant was accepted")
            } catch EmbeddedAdapterError.poisoned(_) { checks += 1 }
        }
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
        try require(ld == ["-arch", "arm64", "-dylib", "-platform_version", "ios", "15.0", "16.5",
                           "-install_name", "@rpath/libanswer.dylib", "-o", linkOutput,
                           root.appendingPathComponent("answer.o").path, root.appendingPathComponent("libSystem.B.tbd").path],
                    "link argv was not the fixed reviewed argv")
        try require(snapshot.stubs == 1 && snapshot.copiedStub == FakeBridge.stub, "verified stub must be copied into the private run")
        try cleanup(result, fake)
        let objcFake = FakeBridge()
        let objc = await EmbeddedToolchainExecutionAdapter(bridge: objcFake).execute(
            sources: ["answer.m": "int answer(void) { return 42; }\n"],
            operations: [.compile(source: "answer.m", output: "answer.o", language: .objectiveC)])
        try require(objc.passed && objcFake.snapshot().calls[0].contains("objective-c") &&
                    objcFake.snapshot().calls[0].contains("-fobjc-arc"), "Objective-C structured language was not translated")
        try cleanup(objc, objcFake)
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
        for samples in [[384 * mib], [385 * mib], [128 * mib, 192 * mib], [128 * mib, 193 * mib]] {
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
