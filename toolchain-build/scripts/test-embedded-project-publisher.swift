import Foundation

private struct PublisherContractFailure: Error { let description: String }

/// Uses the adapter's valid thin-arm64 Mach-O fixture, never executable bytes.
@MainActor
enum ProjectPublisherContracts {
    static func run() throws -> Int {
        var checks = 0
        let fm = FileManager.default
        func require(_ condition: Bool, _ message: String) throws {
            checks += 1
            if !condition { throw PublisherContractFailure(description: message) }
        }
        func reject(_ message: String, _ body: () throws -> Void) throws {
            do { try body() }
            catch is EmbeddedToolchainProjectPublisherError { checks += 1; return }
            catch is CancellationError { checks += 1; return }
            throw PublisherContractFailure(description: "accepted invalid publication: " + message)
        }
        let parent = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("publisher-contract-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: parent) }
        func directory(_ name: String) throws -> URL {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
        let bytes = MachOFixture.image(filetype: 6, installName: "@rpath/project.dylib")
        let root = try directory("project")
        let first = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: "project.dylib", projectRoot: root)
        let output = root.appendingPathComponent(first.relativePath)
        try require(first.relativePath == "build/minis-embedded/project.dylib" && first.architecture == "arm64" && first.filetype == 6,
                    "fixed project-local output shape")
        try require(try Data(contentsOf: output) == bytes && first.sha256 == EmbeddedAdapterArtifact.digest(bytes), "verified on-disk output binding")
        var replacement = bytes; replacement[replacement.count - 1] = 0
        let second = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(replacement, named: "project.dylib", projectRoot: root)
        try require(try Data(contentsOf: output) == replacement && second.sha256 != first.sha256, "atomic same-name replacement")
        try require(try fm.contentsOfDirectory(atPath: output.deletingLastPathComponent().path) == ["project.dylib"], "no partial temporary output")
        for name in ["../project.dylib", "/project.dylib", "project.dylib\n", "a;id.dylib", "nested/project.dylib", "project.o"] {
            try reject("unsafe filename") {
                _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: name, projectRoot: root)
            }
        }
        for invalid in [Data(), Data([1, 2, 3]), Data(repeating: 0, count: 16 * 1024 * 1024 + 1)] {
            try reject("invalid bytes") {
                _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(invalid, named: "project.dylib", projectRoot: root)
            }
        }
        try reject("install-name mismatch") {
            _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: "other.dylib", projectRoot: root)
        }
        try require(try Data(contentsOf: output) == replacement, "failed publications preserve prior complete output")
        let token = EmbeddedAdapterCancellation(); token.cancel()
        try reject("pre-cancel publication") {
            _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: "project.dylib", projectRoot: root, cancellation: token)
        }
        try require(try Data(contentsOf: output) == replacement, "cancellation preserves existing output")
        var committed = false
        try reject("cancel wins critical section") { try token.commitIfNotCancelled { committed = true } }
        try require(!committed, "cancelled token never runs commit body")

        let outside = try directory("outside")
        let buildLinked = try directory("build-linked")
        try fm.createSymbolicLink(at: buildLinked.appendingPathComponent("build"), withDestinationURL: outside)
        try reject("build symlink") {
            _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: "project.dylib", projectRoot: buildLinked)
        }
        let subLinked = try directory("sub-linked")
        let subBuild = subLinked.appendingPathComponent("build", isDirectory: true)
        try fm.createDirectory(at: subBuild, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: subBuild.appendingPathComponent("minis-embedded"), withDestinationURL: outside)
        try reject("output directory symlink") {
            _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: "project.dylib", projectRoot: subLinked)
        }
        let rootLink = parent.appendingPathComponent("root-link", isDirectory: true)
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: root)
        try reject("root symlink") {
            _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: "project.dylib", projectRoot: rootLink)
        }
        try require(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "no symlink destination modified")
        for name in ["Bundle.APP", "Kit.framework", "jb", "preboot", "System"] {
            let unsafe = try directory(name)
            try reject("unsafe system or package root") {
                _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: "project.dylib", projectRoot: unsafe)
            }
        }
        // rename replaces a final symlink entry, never follows its target.
        let outsideFile = outside.appendingPathComponent("sentinel")
        let sentinel = Data("keep".utf8); try sentinel.write(to: outsideFile)
        try fm.removeItem(at: output)
        try fm.createSymbolicLink(at: output, withDestinationURL: outsideFile)
        _ = try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(bytes, named: "project.dylib", projectRoot: root)
        try require(try Data(contentsOf: outsideFile) == sentinel && Data(contentsOf: output) == bytes, "final symlink replaced without following target")
        print("PASS: \(checks) atomic publication/replacement/cancellation/path contracts (no signing or execution)")
        return checks
    }
}
