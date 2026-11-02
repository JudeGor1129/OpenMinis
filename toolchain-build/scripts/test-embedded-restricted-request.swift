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
        let request = try EmbeddedToolchainRestrictedRequestBuilder.make(from: plan)
        try require(request.snapshotFingerprint == snapshot.fingerprint, "snapshot fingerprint binding")
        try require(request.sources == plan.sources && request.operations == plan.operations, "request plan copy")
        try require(request.outputName == "project.dylib", "output binding")
        do {
            var mutated = plan.sources
            mutated["main.c"] = "int changed;\n"
            let bad = EmbeddedToolchainMaterializedPlan(sources: mutated, operations: plan.operations,
                sourceFingerprints: plan.sourceFingerprints, snapshotFingerprint: plan.snapshotFingerprint,
                outputName: plan.outputName)
            _ = try EmbeddedToolchainRestrictedRequestBuilder.make(from: bad)
            throw Failure(description: "content mutation was accepted")
        } catch EmbeddedToolchainRestrictedRequestError.sourceFingerprintMismatch { checks += 1 }
        do {
            var badOps = plan.operations
            badOps.removeLast()
            let bad = EmbeddedToolchainMaterializedPlan(sources: plan.sources, operations: badOps,
                sourceFingerprints: plan.sourceFingerprints, snapshotFingerprint: plan.snapshotFingerprint,
                outputName: plan.outputName)
            _ = try EmbeddedToolchainRestrictedRequestBuilder.make(from: bad)
            throw Failure(description: "missing link was accepted")
        } catch EmbeddedToolchainRestrictedRequestError.invalidOperation { checks += 1 }
        do {
            _ = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "../bad.dylib")
            throw Failure(description: "unsafe materialized output was accepted")
        } catch EmbeddedToolchainProjectMaterializerError.noOperations { checks += 1 }
        print("PASS: \(checks) restricted request fingerprint, operation order, output and mutation contracts")
    }
}
