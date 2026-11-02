import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }

@main @MainActor
struct MaterializerContracts {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1; if !condition() { throw Failure(description: message) }
    }
    static func main() throws {
        let files = [
            "src/main.c": "#include \"value.h\"\nint main_value(void) { return value(); }\n",
            "src/value.h": "#include \"nested.h\"\nint value(void) { return nested(); }\n",
            "src/nested.h": "int nested(void) { return 7; }\n"
        ]
        let snapshot = try EmbeddedToolchainProjectSnapshotBuilder.build(files: files, entrySources: ["src/main.c"])
        let plan = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "project.dylib")
        try require(plan.snapshotFingerprint == snapshot.fingerprint, "snapshot binding")
        try require(plan.sources.count == 1 && plan.sources.keys.first == "src_main.c", "one materialized entry")
        let source = plan.sources["src_main.c"] ?? ""
        try require(source.contains("int nested(void)"), "deep header emitted")
        try require(source.contains("int value(void)"), "direct header emitted")
        try require(source.contains("int main_value(void)"), "entry source emitted")
        try require(!source.contains("#include"), "include directives removed")
        guard case .compile(let firstSource, let firstObject, let firstLanguage) = plan.operations[0] else {
            throw Failure(description: "first operation is not compile")
        }
        try require(firstSource == "src_main.c" && firstObject == "src_main.o" && firstLanguage == .c, "compile operation")
        guard case .link(let objects, let output, let installName) = plan.operations.last else {
            throw Failure(description: "last operation is not link")
        }
        try require(objects == ["src_main.o"] && output == "project.dylib" && installName == "@rpath/project.dylib", "link operation")
        try require(plan.sourceFingerprints["src_main.c"]?.count == 64, "materialized digest")
        let repeated = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "project.dylib")
        try require(plan == repeated, "deterministic materialized plan")
        do {
            _ = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "../escape.dylib")
            throw Failure(description: "unsafe output name accepted")
        } catch EmbeddedToolchainProjectMaterializerError.noOperations { checks += 1 }
        print("PASS: \(checks) snapshot materialization, include order, deduplication, operations and output-boundary contracts")
    }
}
