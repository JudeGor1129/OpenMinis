import Foundation

private struct ExecutionContractFailure: Error { let description: String }

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
        print("PASS: \(checks) restricted execution/capture/cancellation contracts (fake bridge only)")
        return checks
    }
}
