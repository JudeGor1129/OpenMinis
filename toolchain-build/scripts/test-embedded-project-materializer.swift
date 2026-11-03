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
        try require(plan.sources.count == 1 && plan.sources.keys.first == "unit0.c", "one materialized entry")
        let source = plan.sources["unit0.c"] ?? ""
        try require(source.contains("int nested(void)"), "deep header emitted")
        try require(source.contains("int value(void)"), "direct header emitted")
        try require(source.contains("int main_value(void)"), "entry source emitted")
        try require(!source.contains("#include"), "include directives removed")
        guard case .compile(let firstSource, let firstObject, let firstLanguage) = plan.operations[0] else {
            throw Failure(description: "first operation is not compile")
        }
        try require(firstSource == "unit0.c" && firstObject == "unit0.o" && firstLanguage == .c, "compile operation")
        guard let last = plan.operations.last else {
            throw Failure(description: "last operation is missing")
        }
        guard case .link(let objects, let output, let installName) = last else {
            throw Failure(description: "last operation is not link")
        }
        try require(objects == ["unit0.o"] && output == "project.dylib" && installName == "@rpath/project.dylib", "link operation")
        try require(plan.sourceFingerprints["unit0.c"]?.count == 64, "materialized digest")
        let orderedFiles = [
            "src/main.c": "#include \"first.h\"\n#include \"second.h\"\nint order(void) { return first() + second(); }",
            "src/first.h": "int first(void) { return 1; }",
            "src/second.h": "int second(void) { return 2; }"
        ]
        let orderedSnapshot = try EmbeddedToolchainProjectSnapshotBuilder.build(files: orderedFiles)
        let orderedPlan = try EmbeddedToolchainProjectMaterializer.plan(snapshot: orderedSnapshot)
        let orderedText = orderedPlan.sources["unit0.c"] ?? ""
        try require(orderedText.range(of: "int first")!.lowerBound < orderedText.range(of: "int second")!.lowerBound,
                    "include order must match the source")
        let diamondFiles = [
            "src/main.c": "#include \"left.h\"\n#include \"right.h\"\nint run(void);",
            "src/left.h": "#include \"common.h\"\nint left(void);",
            "src/right.h": "#include \"common.h\"\nint right(void);",
            "src/common.h": "int common(void);"
        ]
        let diamond = try EmbeddedToolchainProjectSnapshotBuilder.build(files: diamondFiles)
        let diamondPlan = try EmbeddedToolchainProjectMaterializer.plan(snapshot: diamond)
        let diamondText = diamondPlan.sources["unit0.c"] ?? ""
        try require(diamondText.components(separatedBy: "int common").count - 1 == 2,
                    "unguarded repeated includes must retain C semantics")
        let repeated = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "project.dylib")
        try require(plan == repeated, "deterministic materialized plan")
        do {
            _ = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: "../escape.dylib")
            throw Failure(description: "unsafe output name accepted")
        } catch EmbeddedToolchainProjectMaterializerError.noOperations { checks += 1 }
        print("PASS: \(checks) snapshot materialization, include order, deduplication, operations and output-boundary contracts")
    }
}
