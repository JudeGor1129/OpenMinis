import Foundation

private struct Failure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct SnapshotContracts {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw Failure(description: message) }
    }
    static func rejects(_ files: [String: String], _ message: String) throws {
        do {
            _ = try EmbeddedToolchainProjectSnapshotBuilder.build(files: files)
            throw Failure(description: "accepted unsafe snapshot: \(message)")
        } catch let error as EmbeddedToolchainProjectSnapshotError {
            checks += 1
            guard error.errorDescription != nil else { throw Failure(description: "missing error text: \(message)") }
        }
    }
    static func main() throws {
        let files = [
            "src/main.c": "#include \"value.h\"\nint main_value(void) { return 7; }\n",
            "src/value.h": "#include \"nested.h\"\nint value(void);\n",
            "src/nested.h": "int nested(void);\n"
        ]
        let snapshot = try EmbeddedToolchainProjectSnapshotBuilder.build(files: files, entrySources: ["src/main.c"])
        try require(snapshot.schema == 1, "schema")
        try require(snapshot.dependencies["src/main.c"] == ["src/value.h"], "source include")
        try require(snapshot.dependencies["src/value.h"] == ["src/nested.h"], "header include")
        try require(snapshot.entrySources == ["src/main.c"], "entry source")
        try require(snapshot.files.map(\.path) == ["src/main.c", "src/nested.h", "src/value.h"], "stable file ordering")
        try require(EmbeddedToolchainProjectSnapshotBuilder.materializedFiles(snapshot) == files, "immutable materialization")
        let reversed = try EmbeddedToolchainProjectSnapshotBuilder.build(
            files: Dictionary(uniqueKeysWithValues: files.reversed()), entrySources: ["src/main.c"])
        try require(snapshot == reversed && snapshot.fingerprint == reversed.fingerprint, "deterministic fingerprint")

        try rejects(["/main.c": "int x;"], "absolute path")
        try rejects(["../main.c": "int x;"], "parent path")
        try rejects(["main.C": "int x;"], "uppercase extension")
        try rejects(["main.cpp": "int x;"], "C++ extension")
        try rejects(["main.c": "int café;"], "non ASCII")
        try rejects(["main.c": "#include <stdio.h>\nint x;"], "system include")
        try rejects(["main.c": "#ifdef X\nint x;\n#endif\n"], "conditional")
        try rejects(["main.c": "__asm__(\"nop\");"], "assembly")
        try rejects(["main.c": "#include \"missing.h\"\nint x;"], "missing header")
        try rejects(["main.c": "#include \"../value.h\"\nint x;", "value.h": "int x;"], "include escape")
        try rejects(["main.c": "#include \"a.h\"\nint x;", "a.h": "#include \"b.h\"\n", "b.h": "#include \"a.h\"\n"], "cycle")
        var deep = ["main.c": "#include \"d0.h\"\nint x;"]
        for index in 0...EmbeddedToolchainProjectSnapshotBuilder.maxDependencyDepth {
            deep["d\(index).h"] = index == EmbeddedToolchainProjectSnapshotBuilder.maxDependencyDepth
                ? "int leaf;" : "#include \"d\(index + 1).h\"\n"
        }
        try rejects(deep, "dependency depth")
        try rejects(["main.c": "#define VALUE 1\nint x;"], "macro")
        try rejects(["main.c": "#pragma once\nint x;"], "pragma")
        try require(checks >= 21, "coverage count")
        print("PASS: \(checks) project snapshot, path, directive, dependency, cycle/depth and fingerprint contracts")
    }
}
