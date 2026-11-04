import Foundation

/// Read-only readiness surface for the future in-process Clang/ld64 provider.
///
/// This provider deliberately has no shell command and never falls back to iSH.
/// OM_TOOLCHAIN_ENABLED=1 and OM_TOOLCHAIN_VERIFIED=1 are necessary readiness
/// gates, but are not sufficient: build/test remain unavailable until a reviewed
/// structured-operation execution adapter exists.
/// Target architecture, independent of the arm64 host process. ABI version 0
/// arm64e subtypes are admitted; unknown capability/ABI versions fail closed.
enum EmbeddedToolchainArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64, arm64e
    var cpu: String { self == .arm64e ? "apple-a12" : "apple-a7" }
    func accepts(subtype: UInt32) -> Bool {
        self == .arm64 ? subtype == 0 : (subtype == 2 || subtype == 0x80000002)
    }
}

enum EmbeddedToolchainLanguage: String, Equatable, Sendable {
    case c
    case objectiveC = "objective-c"
}

enum EmbeddedToolchainOperation: Equatable, Sendable {
    case compile(source: String, output: String, language: EmbeddedToolchainLanguage)
    case link(objects: [String], output: String, installName: String)

    private static let maxSourceBytes = 4 * 1024 * 1024
    private static let maxObjectBytes: UInt64 = 16 * 1024 * 1024
    private static let maxTotalObjectBytes: UInt64 = 64 * 1024 * 1024
    private static let maxObjectCount = 32

    /// Pure input policy for the future in-process adapter. It does not invoke
    /// a shell, open a compiler, or make the Provider executable.
    func validationError(root: URL) -> String? {
        let requestedRoot = root.standardizedFileURL
        let rootURL = requestedRoot.resolvingSymlinksInPath()
        guard requestedRoot.path == rootURL.path else {
            return "project root must not be a symlink"
        }
        switch self {
        case let .compile(source, output, language):
            guard let sourceURL = Self.safeURL(source, under: rootURL, existing: true) else {
                return "source escapes the project root, is a symlink, or is missing"
            }
            guard let outputURL = Self.safeURL(output, under: rootURL, existing: false) else {
                return "output escapes the project root or its parent is unsafe"
            }
            guard FileManager.default.fileExists(atPath: sourceURL.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let sourceBytes = (attributes[.size] as? NSNumber)?.uint64Value,
                  sourceBytes <= UInt64(Self.maxSourceBytes) else {
                return "source is not a regular file or exceeds the bounded input size"
            }
            let extensionName = sourceURL.pathExtension.lowercased()
            let expected = language == .c ? "c" : "m"
            guard extensionName == expected else {
                return "language does not match the source extension"
            }
            guard outputURL.pathExtension.lowercased() == "o" else {
                return "compile output must be a Mach-O object path"
            }
            return nil

        case let .link(objects, output, installName):
            guard !objects.isEmpty, objects.count <= Self.maxObjectCount else {
                return "link object count is outside the bounded range"
            }
            var totalObjectBytes: UInt64 = 0
            for object in objects {
                guard let objectURL = Self.safeURL(object, under: rootURL, existing: true),
                      objectURL.pathExtension.lowercased() == "o",
                      let attributes = try? FileManager.default.attributesOfItem(atPath: objectURL.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let objectBytes = (attributes[.size] as? NSNumber)?.uint64Value,
                      objectBytes <= Self.maxObjectBytes,
                      objectBytes <= Self.maxTotalObjectBytes - totalObjectBytes,
                      Self.isArm64Object(at: objectURL) else {
                    return "link input is missing, unsafe, not an arm64 Mach-O object, or exceeds the total size budget"
                }
                totalObjectBytes += objectBytes
            }
            guard let outputURL = Self.safeURL(output, under: rootURL, existing: false),
                  outputURL.pathExtension.lowercased() == "dylib" else {
                return "link output must be a safe dylib path"
            }
            let installParts = installName.split(separator: "/", omittingEmptySubsequences: true)
            let installFile = installParts.count == 2 ? String(installParts[1]) : ""
            let safeInstallFile = installFile.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
                                                   options: .regularExpression) != nil
            guard installName.hasPrefix("@rpath/"), safeInstallFile,
                  !installFile.contains("..") else {
                return "install name must be a single safe @rpath filename"
            }
            return nil
        }
    }

    private static func isArm64Object(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 32 else { return false }
        func word(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) |
                (UInt32(data[offset + 1]) << 8) |
                (UInt32(data[offset + 2]) << 16) |
                (UInt32(data[offset + 3]) << 24)
        }
        guard word(0) == 0xfeedfacf, word(4) == 0x0100000c, word(12) == 1 else { return false }
        let commandCount = Int(word(16))
        let commandBytes = Int(word(20))
        guard commandCount > 0, commandCount <= 4096,
              commandBytes >= commandCount * 8,
              commandBytes <= data.count - 32 else { return false }
        var cursor = 32
        let end = cursor + commandBytes
        for _ in 0..<commandCount {
            guard cursor + 8 <= end else { return false }
            let size = Int(word(cursor + 4))
            guard size >= 8, cursor + size <= end else { return false }
            cursor += size
        }
        return cursor == end
    }

    private static func containsSymlinkComponent(_ relative: String, root: URL) -> Bool {
        var cursor = root
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }

    private static func safeURL(_ relative: String, under root: URL, existing: Bool) -> URL? {
        guard !relative.isEmpty, !relative.contains("\0"), !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else { return nil }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard !Self.containsSymlinkComponent(relative, root: root) else { return nil }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path == root.path || parent.path.hasPrefix(rootPath) else { return nil }
        if existing {
            guard FileManager.default.fileExists(atPath: candidate.path),
                  (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        } else {
            guard FileManager.default.fileExists(atPath: parent.path),
                  (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
            if FileManager.default.fileExists(atPath: candidate.path) {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                      attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            }
        }
        return candidate
    }
}

@MainActor
struct EmbeddedToolchainBuildProvider: BuildProvider {
    let id: BuildProviderID = .embeddedToolchain

    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability {
        let status = OMToolchain.capabilityStatus()
        let linked = status["compiler_linked"] == "yes"
        let verified = status["verification"] == "passed"
        let stateReady = status["state"] == "ready"
        let sdkReady = status["sdk"] == "present"
        let resourcesReady = status["resource_headers"] == "present"
        let architecture = status["host_architecture"] ?? "unknown"
        let architectureSupported = architecture == "arm64" || architecture == "arm64e"

        var missing: [String] = []
        if !linked { missing.append("OM_TOOLCHAIN_ENABLED=1 and matching LLVM/ld64 archives") }
        if !verified { missing.append("OM_TOOLCHAIN_VERIFIED=1 after the enabled compile/link gate") }
        if !resourcesReady { missing.append("matching Clang resource headers") }
        if !sdkReady { missing.append("native iOS SDK") }
        if !architectureSupported { missing.append("arm64 or arm64e host architecture") }
        if !stateReady { missing.append("ready toolchain capability state") }

        let reason: String
        if missing.isEmpty {
            reason = "Native toolchain gates passed; the execution adapter is still intentionally disabled in this build."
        } else {
            reason = "Native in-process compiler is not available; no command was executed."
        }
        return BuildProviderAvailability(
            provider: id,
            state: .unavailable,
            reason: reason,
            missingConfiguration: missing + ["in-process BuildProvider execution adapter"],
            capabilities: [
                "in-process Clang front end (when enabled)",
                "in-process ld64 (when enabled)",
                "architecture-aware readiness reporting",
                "does not spawn a compiler subprocess"
            ]
        )
    }

    func resolvedToolchain(for context: BuildProviderContext) async -> String {
        let status = OMToolchain.capabilityStatus()
        let fields = ["compiler_linked", "verification", "state", "host_architecture", "resource_headers", "sdk"]
            .compactMap { key in status[key].map { "\(key)=\($0)" } }
            .joined(separator: " ")
        return "embedded-omtoolchain: \(fields)"
    }

    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        .unavailable(await availability(for: context))
    }

    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        .unavailable(await availability(for: context))
    }
}
