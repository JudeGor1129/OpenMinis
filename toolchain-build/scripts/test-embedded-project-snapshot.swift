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
    static func rejectsRoot(_ root: URL, _ message: String) throws {
        do {
            _ = try EmbeddedToolchainProjectSnapshotBuilder.load(root: root, entrySources: ["src/main.c"])
            throw Failure(description: "accepted unsafe root: \(message)")
        } catch let error as EmbeddedToolchainProjectSnapshotError {
            checks += 1
            guard error.errorDescription != nil else { throw Failure(description: "missing root error text: \(message)") }
        }
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
    // Real filesystem contracts, not provider/URL spies. Exercise the same shared
    // resolver both native providers call, including Darwin /var and /tmp aliases.
    static func testWorkspaceResolution() throws {
        let fm = FileManager.default
        let bases = [fm.temporaryDirectory.resolvingSymlinksInPath(),
                     URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
        for base in bases {
            let workspace = base.appendingPathComponent("workspace-编译 测试-" + UUID().uuidString, isDirectory: true)
            let project = workspace.appendingPathComponent("theos-smoke", isDirectory: true)
            let nested = workspace.appendingPathComponent("nested/smoke", isDirectory: true)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: workspace) }
            let bytes = Data("THEOS_PACKAGE_SCHEME = rootless\n".utf8)
            try bytes.write(to: project.appendingPathComponent("Makefile"))
            let physicalRoot = try EmbeddedToolchainProjectSnapshotBuilder.validatedRoot(workspace)
            let physicalProject = try EmbeddedToolchainProjectSnapshotBuilder.validatedRoot(project)
            var variants = [workspace, physicalRoot]
            if physicalRoot.path.hasPrefix("/private/var/") || physicalRoot.path.hasPrefix("/private/tmp/") {
                variants.append(URL(fileURLWithPath: String(physicalRoot.path.dropFirst("/private".count)), isDirectory: true))
            }
            let oldChild = physicalRoot.appendingPathComponent("theos-smoke", isDirectory: true).standardizedFileURL
            let oldWouldReject = !oldChild.path.hasPrefix(physicalRoot.path + "/")
            print("INFO: real Darwin workspace alias; mixed physical/standardized guard would reject=\(oldWouldReject)")
            for variant in variants {
                let resolved = try EmbeddedToolchainProjectSnapshotBuilder.resolveWorkspaceProject(
                    guestPath: "/var/minis/workspace/theos-smoke", workspace: variant)
                try require(resolved.path == physicalProject.path, "native resolver preserves physical project for Darwin aliases")
                let readback = try EmbeddedToolchainProjectSnapshotBuilder.readBoundedProjectFile("Makefile", root: resolved, limit: 1024)
                try require(readback == bytes, "resolved project still uses the actual nofollow file reader")
                let nestedResult = try EmbeddedToolchainProjectSnapshotBuilder.resolveWorkspaceProject(
                    guestPath: "/var/minis/workspace/nested/smoke", workspace: variant)
                try require(nestedResult.pathComponents.starts(with: physicalRoot.pathComponents), "nested physical containment")
            }
            func rejectSelection(_ guest: String, root: URL? = nil) throws {
                do {
                    _ = try EmbeddedToolchainProjectSnapshotBuilder.resolveWorkspaceProject(guestPath: guest, workspace: root ?? workspace)
                    throw Failure(description: "accepted unsafe workspace selection: \(guest)")
                } catch let error as EmbeddedToolchainProjectSnapshotError {
                    try require(error.errorDescription != nil, "workspace rejection has a concrete reason")
                }
            }
            for path in ["/var/minis/workspace/", "/var/minis/workspace/../theos-smoke", "/var/minis/workspace//theos-smoke",
                         "/var/minis/workspace/./theos-smoke", "/var/minis/workspace/theos-smoke/",
                         "/var/minis/workspace/nested/../theos-smoke", "/var/minis/workspace/theos-smoke\0suffix",
                         "/var/minis/workspace/\\theos-smoke", "/var/minis/workspace-sibling/theos-smoke",
                         "/tmp/theos-smoke", "theos-smoke", "/var/minis/workspace/missing"] {
                try rejectSelection(path)
            }
            let sibling = workspace.deletingLastPathComponent().appendingPathComponent(workspace.lastPathComponent + "-sibling", isDirectory: true)
            try fm.createDirectory(at: sibling, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: sibling) }
            try rejectSelection("/var/minis/workspace/../" + sibling.lastPathComponent)
            let outsideLink = workspace.appendingPathComponent("outside-link", isDirectory: true)
            try fm.createSymbolicLink(at: outsideLink, withDestinationURL: sibling)
            try rejectSelection("/var/minis/workspace/outside-link")
            let insideLink = workspace.appendingPathComponent("inside-link", isDirectory: true)
            try fm.createSymbolicLink(at: insideLink, withDestinationURL: project)
            try rejectSelection("/var/minis/workspace/inside-link")
            try rejectSelection("/var/minis/workspace/theos-smoke", root: insideLink)
            try rejectSelection("/var/minis/workspace/inside-link/child")
            let linkedAncestor = workspace.appendingPathComponent("nested-link", isDirectory: true)
            try fm.createSymbolicLink(at: linkedAncestor, withDestinationURL: workspace.appendingPathComponent("nested"))
            try rejectSelection("/var/minis/workspace/nested-link/smoke")
            try bytes.write(to: workspace.appendingPathComponent("plain-file"))
            try rejectSelection("/var/minis/workspace/plain-file")
        }
    }

    static func main() throws {
        try testWorkspaceResolution()
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
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("snapshot-root-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("#include \"value.h\"\n#include \"alias.h\"\nint x;\n".utf8).write(to: root.appendingPathComponent("src/main.c"))
        try Data("int value;\n".utf8).write(to: root.appendingPathComponent("src/value.h"))
        try Data("int alias;\n".utf8).write(to: root.appendingPathComponent("src/alias.h"))
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try EmbeddedToolchainProjectSnapshotBuilder.load(root: root, entrySources: ["src/main.c"])
        try require(loaded.files.count == 3 && loaded.dependencies["src/main.c"] == ["src/value.h", "src/alias.h"], "filesystem closure and source include order")
        if root.path.hasPrefix("/private/var/") {
            let varAlias = URL(fileURLWithPath: "/var/" + root.path.dropFirst("/private/var/".count), isDirectory: true)
            let aliasLoaded = try EmbeddedToolchainProjectSnapshotBuilder.load(root: varAlias, entrySources: ["src/main.c"])
            try require(aliasLoaded == loaded, "Darwin /var alias resolves to same physical project")
        }
        try Data("int objc_value(void) { return 42; }\n".utf8).write(to: root.appendingPathComponent("src/second.m"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: false)
        try Data("#include <ignored.h>\n".utf8).write(to: root.appendingPathComponent("build/ignored.c"))
        let scanned = try EmbeddedToolchainProjectSnapshotBuilder.loadProject(root: root)
        try require(scanned.entrySources == ["src/main.c", "src/second.m"] && scanned.files.count == 4,
                    "directory scan finds both languages and skips previous build outputs")
        let comments = try EmbeddedToolchainProjectSnapshotBuilder.build(files: [
            "main.c": "// #include \"missing.h\"\n/* #define BAD */\n/* leading */ #include \"value.h\" // trailing\nint x;",
            "value.h": "int value;"
        ])
        try require(comments.dependencies["main.c"] == ["value.h"], "comment lexer recognizes only visible includes")
        try rejects(["main.c": "/* unclosed\nint x;"], "unterminated comment")
        try rejects(["main.c": "%:include <stdio.h>\n"], "digraph preprocessing")
        try rejects(["main.c": "??=include <stdio.h>\n"], "trigraph preprocessing")
        let link = root.deletingLastPathComponent().appendingPathComponent("snapshot-link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        try rejectsRoot(link, "symlink root")
        try FileManager.default.removeItem(at: root.appendingPathComponent("src/alias.h"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("src/alias.h"), withDestinationURL: root.appendingPathComponent("src/value.h"))
        try rejectsRoot(root, "symlink dependency")
        try require(checks >= 24, "coverage count")
        print("PASS: \(checks) project snapshot, path, directive, dependency, cycle/depth, fingerprint and filesystem contracts")
    }
}
