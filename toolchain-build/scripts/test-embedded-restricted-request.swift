import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }

@main @MainActor
struct RestrictedRequestContracts {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1; if !condition() { throw Failure(description: message) }
    }
    static func main() throws {
        let files = [
            "main.c": "#include \"value.h\"\nint main_value(void) { return value(); }\n",
            "value.h": "int value(void) { return 7; }\n"
        ]
        let snapshot = try EmbeddedToolchainProjectSnapshotBuilder.build(files: files, entrySources: ["main.c"])
        let plan = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "project.dylib")
        let request = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: plan)
        try require(request.snapshotFingerprint == snapshot.fingerprint, "snapshot fingerprint binding")
        try require(request.sources == plan.sources && request.operations == plan.operations, "request plan copy")
        try require(request.outputName == "project.dylib", "output binding")
        try require(request.targetArchitectures == [.arm64], "explicit single-architecture request metadata")
        let universalRequest = try EmbeddedToolchainRestrictedRequestBuilder.make(
            snapshot: snapshot, plan: plan, targetArchitectures: [.arm64, .arm64e])
        try require(universalRequest.targetArchitectures == [.arm64, .arm64e], "canonical universal architecture metadata")
        do {
            _ = try EmbeddedToolchainRestrictedRequestBuilder.make(
                snapshot: snapshot, plan: plan, targetArchitectures: [.arm64e, .arm64])
            throw Failure(description: "noncanonical architecture order was accepted")
        } catch EmbeddedToolchainRestrictedRequestError.invalidTargetArchitectures { checks += 1 }
        do {
            _ = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: plan, targetArchitectures: [])
            throw Failure(description: "empty architecture selection was accepted")
        } catch EmbeddedToolchainRestrictedRequestError.invalidTargetArchitectures { checks += 1 }
        do {
            var mutated = plan.sources
            mutated["main.c"] = "int changed;\n"
            let bad = EmbeddedToolchainMaterializedPlan(sources: mutated, operations: plan.operations,
                sourceFingerprints: plan.sourceFingerprints, snapshotFingerprint: plan.snapshotFingerprint,
                outputName: plan.outputName)
            _ = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: bad)
            throw Failure(description: "content mutation was accepted")
        } catch EmbeddedToolchainRestrictedRequestError.sourceFingerprintMismatch { checks += 1 }
        do {
            var badOps = plan.operations
            badOps.removeLast()
            let bad = EmbeddedToolchainMaterializedPlan(sources: plan.sources, operations: badOps,
                sourceFingerprints: plan.sourceFingerprints, snapshotFingerprint: plan.snapshotFingerprint,
                outputName: plan.outputName)
            _ = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: bad)
            throw Failure(description: "missing link was accepted")
        } catch EmbeddedToolchainRestrictedRequestError.invalidOperation { checks += 1 }
        do {
            _ = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "../bad.dylib")
            throw Failure(description: "unsafe materialized output was accepted")
        } catch EmbeddedToolchainProjectMaterializerError.noOperations { checks += 1 }
        for operations in [
            [plan.operations[0], plan.operations[0], plan.operations[1]],
            [EmbeddedToolchainOperation.compile(source: "unit0.c", output: "unit0.o", language: .objectiveC), plan.operations[1]],
            [plan.operations[0], EmbeddedToolchainOperation.link(objects: [], output: "project.dylib", installName: "@rpath/project.dylib")]
        ] {
            let bad = EmbeddedToolchainMaterializedPlan(sources: plan.sources, operations: operations,
                sourceFingerprints: plan.sourceFingerprints, snapshotFingerprint: plan.snapshotFingerprint, outputName: plan.outputName)
            do {
                _ = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: bad)
                throw Failure(description: "invalid source/language/object set accepted")
            } catch is EmbeddedToolchainRestrictedRequestError { checks += 1 }
        }
        let otherSnapshot = try EmbeddedToolchainProjectSnapshotBuilder.build(files: ["main.c": "int different(void) { return 1; }"])
        let selfSigned = try EmbeddedToolchainProjectMaterializer.plan(snapshot: otherSnapshot)
        do {
            _ = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: selfSigned)
            throw Failure(description: "self-signed foreign snapshot accepted")
        } catch EmbeddedToolchainRestrictedRequestError.snapshotMismatch { checks += 1 }
        print("PASS: \(checks) restricted request fingerprint, operation order, output and mutation contracts")
    }
}
