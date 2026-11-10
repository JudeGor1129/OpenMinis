import Foundation

private struct ExecutionContractFailure: Error { let description: String }

/// A one-shot, bounded async gate. Every continuation is resumed exactly once,
/// either by open() or by its watchdog. open() cancels the watchdog immediately.
private actor ExecutionContractGate {
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var watchdog: Task<Void, Never>?

    func wait() async -> Bool {
        if let result { return result }
        precondition(waiter == nil, "only one waiter per contract gate")
        return await withCheckedContinuation { continuation in
            waiter = continuation
            watchdog = Task {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return }
                self.finish(false)
            }
        }
    }

    func open() { finish(true) }

    private func finish(_ value: Bool) {
        guard result == nil else { return }
        result = value
        let continuation = waiter
        waiter = nil
        watchdog?.cancel()
        watchdog = nil
        continuation?.resume(returning: value)
    }
}

private enum ScopedDeliveryOutcome: Sendable {
    case published(EmbeddedToolchainPublishedArtifact)
    case cancelled
    case gateTimedOut
    case failed(String)
}

/// Compiled beside the adapter harness; FakeBridge is the same test seam.
@MainActor
enum RestrictedExecutionContracts {
    static func run() async throws -> Int {
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            checks += 1
            if !condition { throw ExecutionContractFailure(description: message) }
        }
        let snapshot = try EmbeddedToolchainProjectSnapshotBuilder.build(files: [
            "src/main.c": "#include \"api.h\"\nint answer(void) { return value(); }\n",
            "src/api.h": "int value(void);\n",
            "src/value.m": "@interface Root\n+ (int)value;\n@end\n@implementation Root\n+ (int)value { return 42; }\n@end\nint value(void) { return [Root value]; }\n"
        ])
        let plan = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot)
        let request = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: plan)
        try require(request.sources.count == 2 && request.operations.count == 3, "two-source immutable request")
        let fake = FakeBridge()
        let executor = EmbeddedToolchainRestrictedExecutor(adapter: EmbeddedToolchainExecutionAdapter(bridge: fake))
        let report = await executor.execute(request, captureVerifiedDylib: true)
        try require(report.passed && report.requestFingerprint == snapshot.fingerprint, "request-to-execution binding")
        try require(fake.snapshot().kinds == ["compile", "compile", "link"], "all sources compiled before one link")
        try require(fake.snapshot().objcStubs == 1 && fake.snapshot().stubs == 1, "both reviewed runtime stubs used")
        try require(!report.outputFilesPublished && !report.outputExecutionAttempted && !report.providerExecutable, "executor does not publish or execute")
        guard let bytes = report.dylibData, let artifact = report.verifiedArtifact else {
            throw ExecutionContractFailure(description: "missing verified in-memory output")
        }
        try require(artifact.bytes == bytes.count && artifact.sha256 == EmbeddedAdapterArtifact.digest(bytes), "capture size/hash binding")
        try require(report.adapter.temporaryOutputsRemoved && fake.snapshot().roots.allSatisfy {
            !FileManager.default.fileExists(atPath: $0)
        }, "private run directories removed before returning capture")
        let encoded = try JSONEncoder().encode(report.adapter)
        let decoded = try JSONDecoder().decode(EmbeddedAdapterResult.self, from: encoded)
        try require(decoded.capturedDylibData == nil && !decoded.providerExecutable && !decoded.outputExecutionAttempted,
                    "decoded report cannot restore output capability")
        let uncaptured = await executor.execute(request)
        try require(uncaptured.passed && uncaptured.dylibData == nil && uncaptured.verifiedArtifact == nil, "capture is explicit opt-in")

        let universalRequest = try EmbeddedToolchainRestrictedRequestBuilder.make(
            snapshot: snapshot, plan: plan, targetArchitectures: [.arm64, .arm64e])
        let metadata = EmbeddedDebMetadata(packageID: "com.minis.test", name: "Test tweak",
            version: "1.0", maintainer: "Contract", description: "Synthetic dual-target contract",
            tweakName: "project", bundleIDs: ["com.example.target"])
        let universalFake = FakeBridge()
        let universalExecutor = EmbeddedToolchainRestrictedExecutor(
            adapter: EmbeddedToolchainExecutionAdapter(bridge: universalFake))
        let universal = await universalExecutor.executeUniversal(universalRequest, metadata: metadata)
        try require(universal.passed && universal.requestFingerprint == snapshot.fingerprint,
                    "validated dual-target request reaches FAT and DEB packaging")
        try require(universalFake.snapshot().kinds == ["compile", "compile", "link", "compile", "compile", "link"],
                    "both targets independently compile all inputs and link once")
        try require(universal.universalArtifact?.architectures == ["arm64", "arm64e"] &&
                    universal.debArtifact?.universal.architectures == ["arm64", "arm64e"],
                    "FAT dylib and rootless DEB both verify exact architecture slices")
        try require(universal.debArtifact?.filename == metadata.filename &&
                    universal.debData != nil && !universal.outputFilesPublished &&
                    !universal.outputExecutionAttempted && !universal.providerExecutable,
                    "verified package is in-memory only before explicit publication")
        try require(universal.adapterReports.map(\.processLinkCount) == [1, 2] &&
                    universal.adapterReports.allSatisfy(\.temporaryOutputsRemoved),
                    "two-link budget and per-target cleanup evidence")
        let secondFailureFake = FakeBridge(link: [.ok, .diagnostics])
        let secondFailure = await EmbeddedToolchainRestrictedExecutor(
            adapter: EmbeddedToolchainExecutionAdapter(bridge: secondFailureFake))
            .executeUniversal(universalRequest, metadata: metadata)
        try require(!secondFailure.passed && secondFailure.universalData == nil && secondFailure.debData == nil,
                    "second-target failure does not expose first slice or a partial package")
        let singleRequestFake = FakeBridge()
        let singleAsUniversal = await EmbeddedToolchainRestrictedExecutor(
            adapter: EmbeddedToolchainExecutionAdapter(bridge: singleRequestFake))
            .executeUniversal(request, metadata: metadata)
        try require(!singleAsUniversal.passed && singleRequestFake.snapshot().calls.isEmpty,
                    "single-architecture request cannot enter the universal transaction")

        let preToken = EmbeddedAdapterCancellation(); preToken.cancel()
        let preFake = FakeBridge()
        let pre = await EmbeddedToolchainRestrictedExecutor(adapter: EmbeddedToolchainExecutionAdapter(bridge: preFake))
            .execute(request, captureVerifiedDylib: true, cancellation: preToken)
        try require(pre.adapter.state == "cancelled" && preFake.snapshot().calls.isEmpty && pre.dylibData == nil, "pre-cancel: no calls/capture")
        let duringToken = EmbeddedAdapterCancellation()
        let duringFake = FakeBridge(cancelAfterCompile: duringToken)
        let during = await EmbeddedToolchainRestrictedExecutor(adapter: EmbeddedToolchainExecutionAdapter(bridge: duringFake))
            .execute(request, captureVerifiedDylib: true, cancellation: duringToken)
        try require(during.adapter.state == "cancelled" && duringFake.snapshot().kinds == ["compile"] && during.dylibData == nil,
                    "during-cancel: no link or partial capture")
        for failure in [Outcome.diagnostics, .malformed, .encrypted] {
            let failedFake = FakeBridge(link: [failure])
            let failed = await EmbeddedToolchainRestrictedExecutor(adapter: EmbeddedToolchainExecutionAdapter(bridge: failedFake))
                .execute(request, captureVerifiedDylib: true)
            try require(!failed.passed && failed.dylibData == nil && failed.verifiedArtifact == nil && failed.adapter.artifacts.isEmpty,
                        "failed link never exposes capture or partial metadata")
            try require(failed.adapter.temporaryOutputsRemoved && failedFake.snapshot().roots.allSatisfy {
                !FileManager.default.fileExists(atPath: $0)
            }, "failed link cleanup")
        }
        checks += try await sharedCancellationContracts(request: universalRequest, metadata: metadata)
        print("PASS: \(checks) restricted execution/capture/cancellation contracts (fake bridge only)")
        return checks
    }

    private static func sharedCancellationContracts(request: EmbeddedToolchainRestrictedRequest,
                                                    metadata: EmbeddedDebMetadata) async throws -> Int {
        var checks = 0
        func require(_ condition: Bool, _ message: String) throws {
            checks += 1
            if !condition { throw ExecutionContractFailure(description: message) }
        }
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("shared-cancellation-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: parent) }
        func project(_ name: String) throws -> (URL, URL) {
            let root = parent.appendingPathComponent(name, isDirectory: true)
            let output = root.appendingPathComponent(EmbeddedToolchainProjectPublisher.outputDirectory, isDirectory: true)
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            return (root, output)
        }
        // A distinct, valid old package makes accidental replacement observable.
        var oldArm64 = MachOFixture.image(filetype: 6, installName: "@rpath/" + metadata.dylibName)
        oldArm64[oldArm64.count - 1] = 0
        var oldArm64e = MachOFixture.image(filetype: 6, installName: "@rpath/" + metadata.dylibName,
                                           arm64e: true)
        oldArm64e[oldArm64e.count - 1] = 0
        let oldFat = try EmbeddedToolchainUniversalBinary.merge(
            arm64: oldArm64, arm64e: oldArm64e, name: metadata.dylibName)
        let oldDeb = try EmbeddedToolchainDebPackage.build(dylib: oldFat, metadata: metadata)

        // The ordinary path must really execute both fake slices, package and publish.
        let (normalRoot, normalOutput) = try project("normal")
        let normalFake = FakeBridge()
        let normalExecutor = EmbeddedToolchainRestrictedExecutor(adapter: EmbeddedToolchainExecutionAdapter(bridge: normalFake))
        let normal = await EmbeddedToolchainCancellationScope.run { token in
            let delivery = await normalExecutor.executeUniversal(request, metadata: metadata, cancellation: token)
            guard delivery.passed, let deb = delivery.debData, let evidence = delivery.debArtifact else {
                return ScopedDeliveryOutcome.failed("normal delivery: " + delivery.reason)
            }
            do {
                let published = try await Task.detached {
                    try EmbeddedToolchainProjectPublisher.publishRootlessDeb(
                        deb, metadata: metadata, projectRoot: normalRoot, cancellation: token)
                }.value
                guard published.sha256 == evidence.sha256, published.bytes == evidence.bytes else {
                    return .failed("published artifact does not match delivery evidence")
                }
                return .published(published)
            } catch { return .failed("normal publish: \(error)") }
        }
        guard case let .published(published) = normal else {
            throw ExecutionContractFailure(description: "uncancelled scope must publish: \(normal)")
        }
        let normalDeb = try Data(contentsOf: normalOutput.appendingPathComponent(metadata.filename))
        try require(published.artifactKind == "rootless_deb" &&
                    published.sha256 == EmbeddedAdapterArtifact.digest(normalDeb) && normalDeb != oldDeb,
                    "normal scope publishes verified new DEB")
        try require(try fm.contentsOfDirectory(atPath: normalOutput.path) == [metadata.filename] &&
                    normalFake.snapshot().kinds == ["compile", "compile", "link", "compile", "compile", "link"],
                    "normal scope performs both slices without temporary output")

        let (cancelRoot, cancelOutput) = try project("cancel")
        let oldPath = cancelOutput.appendingPathComponent(metadata.filename)
        try oldDeb.write(to: oldPath)
        let cancelFake = FakeBridge()
        let cancelExecutor = EmbeddedToolchainRestrictedExecutor(adapter: EmbeddedToolchainExecutionAdapter(bridge: cancelFake))
        let deliveryReady = ExecutionContractGate()
        let publishRelease = ExecutionContractGate()
        let task = Task {
            await EmbeddedToolchainCancellationScope.run { token in
                let delivery = await cancelExecutor.executeUniversal(request, metadata: metadata, cancellation: token)
                guard delivery.passed, let deb = delivery.debData else {
                    await deliveryReady.open()
                    return ScopedDeliveryOutcome.failed("delivery before cancellation: " + delivery.reason)
                }
                await deliveryReady.open()
                guard await publishRelease.wait() else { return .gateTimedOut }
                do {
                    // A detached child does not inherit cancellation: this only
                    // works if the very same scope token reaches the publisher.
                    let artifact = try await Task.detached {
                        try EmbeddedToolchainProjectPublisher.publishRootlessDeb(
                            deb, metadata: metadata, projectRoot: cancelRoot, cancellation: token)
                    }.value
                    return .published(artifact)
                } catch is CancellationError { return .cancelled }
                catch { return .failed("cancelled publish: \(error)") }
            }
        }
        let reachedPublicationBoundary = await deliveryReady.wait()
        task.cancel()
        await publishRelease.open()
        let cancelled = await task.value
        try require(reachedPublicationBoundary, "delivery must reach the pre-publication barrier before timeout")
        guard case .cancelled = cancelled else {
            throw ExecutionContractFailure(description: "cancelled scope published or failed unexpectedly: \(cancelled)")
        }
        try require(cancelFake.snapshot().kinds == ["compile", "compile", "link", "compile", "compile", "link"],
                    "both delivery slices completed before cancellation")
        try require(try Data(contentsOf: oldPath) == oldDeb, "cancelled publication preserves old DEB byte-for-byte")
        try require(try fm.contentsOfDirectory(atPath: cancelOutput.path) == [metadata.filename],
                    "cancelled publication returns no artifact and leaves no temporary files")

        // Cancel the parent Task before it enters the scope, without any sleeps.
        let preEntryReady = ExecutionContractGate()
        let preEntryRelease = ExecutionContractGate()
        let preFake = FakeBridge()
        let preExecutor = EmbeddedToolchainRestrictedExecutor(adapter: EmbeddedToolchainExecutionAdapter(bridge: preFake))
        let preTask = Task {
            await preEntryReady.open()
            guard await preEntryRelease.wait() else { return false }
            return await EmbeddedToolchainCancellationScope.run { token in
                let alreadyCancelled = token.isCancelled
                let delivery = await preExecutor.executeUniversal(request, metadata: metadata, cancellation: token)
                return alreadyCancelled && !delivery.passed && delivery.debData == nil && delivery.reason == "cancelled"
            }
        }
        let preReady = await preEntryReady.wait()
        preTask.cancel()
        await preEntryRelease.open()
        let preCancelled = await preTask.value
        try require(preReady && preCancelled && preFake.snapshot().calls.isEmpty,
                    "already-cancelled parent enters scope with token cancelled and no bridge calls")
        return checks
    }
}
