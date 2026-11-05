import Foundation
import Darwin

struct EmbeddedTheosBuiltArtifact: Equatable, Sendable {
    /// Verified Mach-O bytes retained in memory for the packaging step only.
    /// Never written outside the private run directory, never executed.
    let data: Data
    let targetName: String
    let kind: EmbeddedTheosTargetKind
    let architecture: String
    let bytes: Int
    let sha256: String
    let filetype: UInt32
    let installedPath: String
    let signatureIdentifier: String
    let signatureCodeSlots: Int
    let adHocSigned: Bool
    let entitlementsEmbedded: Bool
    let entitlementsBytes: Int
}

struct EmbeddedTheosExecutionOutcome: Sendable {
    var artifacts: [EmbeddedTheosBuiltArtifact] = []
    var attempts: Int = 0
    var linkCount: Int = 0
    var temporaryOutputsRemoved = true
    var failure: String?

    var passed: Bool { failure == nil && temporaryOutputsRemoved && !artifacts.isEmpty }
}

enum EmbeddedTheosExecutorError: Error, Equatable, LocalizedError, Sendable {
    case missingToolchain(String)
    case missingSDK
    case compileFailed(String, Int32, String)
    case linkFailed(String, Int32, String)
    case invalidOutput(String)
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .missingToolchain(let detail): return "embedded Theos toolchain is not ready: \(detail)"
        case .missingSDK: return "no usable iPhoneOS SDK is available to the in-process Theos adapter"
        case .compileFailed(let unit, let status, let text): return "compile failed (\(unit), status \(status)): \(text)"
        case .linkFailed(let target, let status, let text): return "link failed (\(target), status \(status)): \(text)"
        case .invalidOutput(let detail): return "generated Mach-O rejected: \(detail)"
        case .cleanupFailed: return "temporary Theos outputs could not be removed"
        }
    }
}

/// In-process Theos adapter: it compiles and links the typed target graph with the
/// already-linked Clang/ld64 bridge. It never runs a shell, Makefile recipe, package
/// hook, or generated code, and it never signs, installs or loads an output.
enum EmbeddedTheosExecutor {
    static let maxCompileUnits = 256
    static let maxOutputBytes = 32 * 1024 * 1024

    static func execute(plans: [EmbeddedTheosTargetPlan],
                        cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) throws -> EmbeddedTheosExecutionOutcome {
        let status = OMToolchain.capabilityStatus()
        guard status["compiler_linked"] == "yes", status["verification"] == "passed",
              status["state"] == "ready" else {
            throw EmbeddedTheosExecutorError.missingToolchain(
                "compiler_linked=\(status["compiler_linked"] ?? "unknown") verification=\(status["verification"] ?? "unknown") state=\(status["state"] ?? "unknown")")
        }
        guard let sysroot = status["sysroot"], !sysroot.isEmpty, status["sdk"] == "present",
              !sysroot.hasSuffix("/") || sysroot.count > 1 else {
            throw EmbeddedTheosExecutorError.missingSDK
        }
        let resourceDir = status["resource_dir"].flatMap { $0.isEmpty ? nil : $0 }
        let minimumIOS = "15.4"
        let fileManager = FileManager.default
        let runRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("minis-theos-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: runRoot, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        var outcome = EmbeddedTheosExecutionOutcome()
        var cleanupNeeded = true
        defer {
            if cleanupNeeded {
                do {
                    try fileManager.removeItem(at: runRoot)
                    if fileManager.fileExists(atPath: runRoot.path) { outcome.temporaryOutputsRemoved = false }
                } catch { outcome.temporaryOutputsRemoved = false }
            }
        }

        func materialize(_ path: String, contents: String, expectedHash: String,
                         under snapshotRoot: URL) throws -> URL {
            let bytes = Data(contents.utf8)
            guard EmbeddedAdapterArtifact.digest(bytes) == expectedHash else {
                throw EmbeddedTheosExecutorError.invalidOutput("snapshot hash mismatch for \(path)")
            }
            let destination = snapshotRoot.appendingPathComponent(path, isDirectory: false)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: destination, options: .withoutOverwriting)
            return destination
        }

        func compile(_ source: EmbeddedTheosMaterializedSource, arch: EmbeddedToolchainArchitecture,
                     sourceURL: URL, includeDirs: [String], objectURL: URL) throws {
            var arguments = OMToolchain.cc1Arguments(
                forSource: sourceURL.path, outputPath: objectURL.path,
                sysroot: sysroot, resourceDir: resourceDir,
                archName: arch.rawValue, minimumIOS: minimumIOS)
            for dir in includeDirs { arguments.append(contentsOf: ["-I", dir]) }
            var out: NSString?
            var err: NSString?
            let status = OMToolchain.runCC1(arguments, stdout: &out, stderr: &err)
            outcome.attempts += 1
            guard status.rawValue == 0 else {
                throw EmbeddedTheosExecutorError.compileFailed(source.path, Int32(status.rawValue),
                                                              String(((err as String?) ?? "").prefix(2000)))
            }
        }

        for plan in plans {
            guard !cancellation.isCancelled else { outcome.failure = "cancelled"; return outcome }
            let snapshotRoot = runRoot.appendingPathComponent("snapshot", isDirectory: true)
                .appendingPathComponent(plan.target.name, isDirectory: true)
            try fileManager.createDirectory(at: snapshotRoot, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            var sourceURLs: [String: URL] = [:]
            for source in plan.sources {
                sourceURLs[source.path] = try materialize(source.path, contents: source.contents,
                    expectedHash: source.sha256, under: snapshotRoot)
            }
            for header in plan.headers {
                _ = try materialize(header.path, contents: header.contents,
                    expectedHash: header.sha256, under: snapshotRoot)
            }
            let includeDirs = Set([snapshotRoot.path] +
                (plan.sources.map(\.path) + plan.headers.map(\.path)).map { path in
                    snapshotRoot.appendingPathComponent(path).deletingLastPathComponent().path
                }).sorted()
            let entitlementURL: URL?
            if let canonical = plan.entitlements {
                let destination = runRoot.appendingPathComponent("\(plan.target.name)-entitlements.plist")
                try canonical.write(to: destination, options: .withoutOverwriting)
                entitlementURL = destination
            } else {
                entitlementURL = nil
            }
            let entitlementBytes = plan.entitlements
            for arch in plan.architectures {
                guard !cancellation.isCancelled else { outcome.failure = "cancelled"; return outcome }
                var objects: [String] = []
                for source in plan.sources {
                    let object = runRoot.appendingPathComponent(
                        "\(plan.target.name)-\(arch.rawValue)-\(EmbeddedTheosTargetPlan.objectName(for: source.path))")
                    guard let sourceURL = sourceURLs[source.path] else {
                        throw EmbeddedTheosExecutorError.invalidOutput("source missing from private snapshot: \(source.path)")
                    }
                    try compile(source, arch: arch, sourceURL: sourceURL,
                        includeDirs: includeDirs, objectURL: object)
                    objects.append(object.path)
                }
                let outputName = plan.target.kind == .tweak ? "\(plan.target.name).dylib" : plan.target.name
                let output = runRoot.appendingPathComponent("\(arch.rawValue)-\(outputName)")
                var linkArguments = ["-arch", arch.rawValue, "-adhoc_codesign"]
                if let entitlementURL {
                    linkArguments += ["-adhoc_codesign_entitlements", entitlementURL.path]
                }
                linkArguments += plan.target.kind == .tweak
                    ? ["-dylib", "-install_name", plan.target.installName ?? "@rpath/\(plan.target.name).dylib"]
                    : ["-execute", "-e", "_main"]
                linkArguments += ["-syslibroot", sysroot, "-platform_version", "ios", minimumIOS, "16.5",
                                  "-o", output.path]
                linkArguments += objects
                for framework in plan.target.frameworks { linkArguments += ["-framework", framework] }
                linkArguments += ["-lSystem"]
                var linkOut: NSString?
                var linkErr: NSString?
                outcome.linkCount += 1
                let status = OMToolchain.runLinker(linkArguments, stdout: &linkOut, stderr: &linkErr)
                guard status.rawValue == 0 else {
                    throw EmbeddedTheosExecutorError.linkFailed(plan.target.name, Int32(status.rawValue),
                                                                String(((linkErr as String?) ?? "").prefix(2000)))
                }
                let descriptor = open(output.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw EmbeddedTheosExecutorError.invalidOutput(outputName) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var attributes = stat()
                guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
                      attributes.st_size > 0, attributes.st_size <= off_t(maxOutputBytes) else {
                    throw EmbeddedTheosExecutorError.invalidOutput(outputName)
                }
                let data = (try? handle.read(upToCount: maxOutputBytes + 1)) ?? Data()
                guard data.count == Int(attributes.st_size) else {
                    throw EmbeddedTheosExecutorError.invalidOutput(outputName)
                }
                let filetype: UInt32 = plan.target.kind == .tweak ? 6 : 2
                let artifact: EmbeddedAdapterArtifact
                let signature: EmbeddedCodeSignatureReport
                do {
                    artifact = try EmbeddedAdapterArtifact.inspect(data, name: outputName,
                                                                   filetype: filetype, architecture: arch)
                    signature = try EmbeddedCodeSignature.verify(data,
                        expectedEntitlements: entitlementBytes)
                    guard signature.adHoc else {
                        throw EmbeddedCodeSignatureError.malformed("CMS signature present; expected ad-hoc")
                    }
                } catch {
                    throw EmbeddedTheosExecutorError.invalidOutput("\(outputName): \(error.localizedDescription)")
                }
                outcome.artifacts.append(EmbeddedTheosBuiltArtifact(
                    data: data,
                    targetName: plan.target.name, kind: plan.target.kind, architecture: arch.rawValue,
                    bytes: artifact.bytes, sha256: artifact.sha256, filetype: filetype,
                    installedPath: EmbeddedTheosDebPackage.rootlessPrefix + plan.target.installPath,
                    signatureIdentifier: signature.identifier,
                    signatureCodeSlots: signature.codeSlots, adHocSigned: signature.adHoc,
                    entitlementsEmbedded: signature.entitlementsPresent,
                    entitlementsBytes: signature.entitlementsBytes))
            }
        }
        do {
            try fileManager.removeItem(at: runRoot)
            guard !fileManager.fileExists(atPath: runRoot.path) else {
                throw EmbeddedTheosExecutorError.cleanupFailed
            }
            cleanupNeeded = false
        } catch {
            outcome.temporaryOutputsRemoved = false
            outcome.failure = "temporary Theos outputs could not be removed"
            cleanupNeeded = false
        }
        return outcome
    }
}
