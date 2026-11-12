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

    private struct PreparedRequest: Sendable {
        let root: URL
        let snapshot: EmbeddedToolchainProjectSnapshot
        let plan: EmbeddedToolchainMaterializedPlan
        let request: EmbeddedToolchainRestrictedRequest
        let metadata: EmbeddedDebMetadata
        let artifactGuestPath: String
    }

    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability {
        let capabilities = [
            "restricted C/Objective-C source subset",
            "separate native arm64 and arm64e compile/link",
            "FAT rootless DEB with verified slices",
            "no shell, install, signing, or generated-code execution"
        ]
        do {
            _ = try await prepare(context)
        } catch {
            return BuildProviderAvailability(provider: id, state: .unavailable,
                reason: error.localizedDescription, missingConfiguration: ["session workspace project with valid MinisTweak.json"],
                capabilities: capabilities)
        }
        let status = OMToolchain.capabilityStatus()
        let verificationOK = status["verification"] == "passed" || status["experimental_build"] == "yes"
        let required: [(String, String)] = [
            ("compiler_linked", "yes"),
            ("resource_headers", "present"), ("sdk", "present"), ("state", "ready")
        ]
        var missing = required.compactMap { key, value in status[key] == value ? nil : key + "=" + value }
        if !verificationOK { missing.append("verification=" + (status["verification"] ?? "missing")) }
        guard status["host_architecture"] == "arm64" || status["host_architecture"] == "arm64e" else {
            return BuildProviderAvailability(provider: id, state: .unavailable,
                reason: "The in-process compiler host architecture is unsupported.",
                missingConfiguration: missing + ["arm64 or arm64e host"], capabilities: capabilities)
        }
        guard missing.isEmpty else {
            return BuildProviderAvailability(provider: id, state: .unavailable,
                reason: "The verified in-process compiler or pinned SDK is not ready; no command was run.",
                missingConfiguration: missing, capabilities: capabilities)
        }
        return BuildProviderAvailability(provider: id, state: .available,
            reason: "The selected session-workspace tweak passes the restricted native build preflight.",
            missingConfiguration: [], capabilities: capabilities)
    }

    func resolvedToolchain(for context: BuildProviderContext) async -> String {
        let status = OMToolchain.capabilityStatus()
        let fields = ["compiler_linked", "verification", "state", "host_architecture", "resource_headers", "sdk"]
            .compactMap { key in status[key].map { "\(key)=\($0)" } }
            .joined(separator: " ")
        return "embedded-omtoolchain: " + fields
    }

    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let started = Date()
        let cancellation = EmbeddedAdapterCancellation()
        return await withTaskCancellationHandler {
            var reports: [EmbeddedAdapterResult] = []
            do {
                guard !cancellation.isCancelled else { throw CancellationError() }
                let ready = await availability(for: context)
                guard !cancellation.isCancelled else { throw CancellationError() }
                guard ready.isAvailable else { return .unavailable(ready) }
                let prepared = try await prepare(context)
                guard !cancellation.isCancelled else { throw CancellationError() }
                let delivery = await EmbeddedToolchainRestrictedExecutor.shared.executeUniversal(
                    prepared.request, metadata: prepared.metadata, cancellation: cancellation)
                reports = delivery.adapterReports
                guard delivery.passed, let deb = delivery.debData,
                      let debEvidence = delivery.debArtifact,
                      let universal = delivery.universalArtifact else {
                    return failedExecution(delivery.reason.isEmpty ? "native dual-target build or DEB verification failed" : delivery.reason,
                        runID: runID, started: started, reports: reports)
                }
                // Check all in-memory evidence before committing the destination.
                guard reports.count == 2, universal.slices.count == 2,
                      reports[0].artifacts.contains(where: { $0.architecture == "arm64" && $0.sha256 == universal.slices[0].sha256 }),
                      reports[1].artifacts.contains(where: { $0.architecture == "arm64e" && $0.sha256 == universal.slices[1].sha256 }) else {
                    return failedExecution("per-architecture thin artifact evidence is incomplete",
                        runID: runID, started: started, reports: reports)
                }
                let published = try await Task.detached(priority: .userInitiated) {
                    try EmbeddedToolchainProjectPublisher.publishRootlessDeb(
                        deb, metadata: prepared.metadata, projectRoot: prepared.root, cancellation: cancellation)
                }.value
                // A committed rename wins a concurrent late cancellation. The publisher
                // has independently read back the committed directory entry.
                guard published.sha256 == debEvidence.sha256, published.bytes == debEvidence.bytes else {
                    return failedExecution("published DEB does not match the verified in-memory package; destination may already be replaced",
                        runID: runID, started: started, reports: reports)
                }
                let stderr = reports.flatMap(\.steps).map(\.stderr).filter { !$0.isEmpty }.joined(separator: "\n")
                let (safeStderr, _) = EnvVarRedactor.redactIfEnabled(String(stderr.prefix(6000)))
                let artifactPath = prepared.artifactGuestPath
                var metadata = reportMetadata(reports)
                metadata["artifact_path"] = artifactPath
                metadata["artifact_sha256"] = published.sha256
                metadata["artifact_bytes"] = String(published.bytes)
                metadata["fat_sha256"] = universal.sha256
                metadata["directory_synced"] = String(published.directorySynced)
                let execution = BuildCommandExecution(command: "embedded-toolchain: arm64 + arm64e -> rootless DEB", exitCode: 0,
                    durationSeconds: Date().timeIntervalSince(started), stdoutSummary: reportSummary(reports),
                    stderrSummary: safeStderr, fullLogPath: "", diagnosticExcerpt: safeStderr,
                    remoteMetadata: metadata, remoteJobs: [], remoteArtifacts: [])
                return .completedWithArtifacts(execution, [verifiedDEB(published, evidence: debEvidence,
                    universal: universal, guestPath: artifactPath, metadata: prepared.metadata)])
            } catch {
                if let publisherError = error as? EmbeddedToolchainProjectPublisherError,
                   case let .committedButUnverified(_, directorySynced) = publisherError {
                    return failedExecution(error.localizedDescription, runID: runID, started: started,
                        reports: reports, extraMetadata: ["publication_committed": "true",
                                                         "directory_synced": String(directorySynced),
                                                         "artifact_available": "false"])
                }
                return failedExecution(error is CancellationError ? "cancelled before publication" : error.localizedDescription,
                    runID: runID, started: started, reports: reports)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        return .unavailable(.init(provider: id, state: .unavailable,
            reason: "The restricted native adapter builds and packages a tweak but does not run generated code or tests on device.",
            missingConfiguration: ["separate authorized device test workflow"], capabilities: availability.capabilities))
    }

    private func prepare(_ context: BuildProviderContext) async throws -> PreparedRequest {
        guard context.request.provider == .embeddedToolchain else {
            throw EmbeddedAdapterError.rejected("select provider=embedded_toolchain explicitly")
        }
        guard context.request.command == nil && context.request.testCommand == nil else {
            throw EmbeddedAdapterError.rejected("embedded_toolchain accepts no shell command or test command")
        }
        guard let workspace = context.nativeWorkspaceRoot else {
            throw EmbeddedAdapterError.rejected("no native URL for the active chat session workspace")
        }
        let root = try Self.resolveProjectRoot(guestPath: context.request.projectPath, workspace: workspace)
        let requestPath = context.request.projectPath
        let requestedArtifacts = context.request.artifactPaths
        let prepared = try await Task.detached(priority: .userInitiated) {
            let manifest = try EmbeddedToolchainTweakManifest.load(from: root)
            let snapshot = try EmbeddedToolchainProjectSnapshotBuilder.loadProject(root: root)
            let plan = try EmbeddedToolchainProjectMaterializer.plan(
                snapshot: snapshot, outputName: manifest.package.dylibName)
            let request = try EmbeddedToolchainRestrictedRequestBuilder.make(
                snapshot: snapshot, plan: plan, targetArchitectures: [.arm64, .arm64e])
            let guestOutput = requestPath + "/" + EmbeddedToolchainProjectPublisher.outputDirectory + "/" + manifest.package.filename
            if !requestedArtifacts.isEmpty && requestedArtifacts != [guestOutput] {
                throw EmbeddedAdapterError.rejected("artifact_paths, when supplied, must name the generated DEB inside this project")
            }
            return PreparedRequest(root: root, snapshot: snapshot, plan: plan, request: request,
                                  metadata: manifest.package, artifactGuestPath: guestOutput)
        }.value
        return prepared
    }

    private static func resolveProjectRoot(guestPath: String, workspace: URL) throws -> URL {
        try EmbeddedToolchainProjectSnapshotBuilder.resolveWorkspaceProject(
            guestPath: guestPath, workspace: workspace)
    }

    private func verifiedDEB(_ published: EmbeddedToolchainPublishedArtifact,
                             evidence: EmbeddedDebArtifact, universal: EmbeddedUniversalArtifact,
                             guestPath: String, metadata: EmbeddedDebMetadata) -> ArtifactVerificationResult {
        let control: [String: String] = [
            "Package": metadata.packageID,
            "Name": metadata.name,
            "Version": metadata.version,
            "Architecture": "iphoneos-arm64",
            "Maintainer": metadata.maintainer,
            "Description": metadata.description,
            "Section": "Tweaks",
            "Priority": "optional",
            "Depends": "firmware (>= 15.0), mobilesubstrate"
        ]
        let capabilities = [
            VerificationCapability(name: "sha256", state: .verified, detail: "final file readback: " + published.sha256),
            VerificationCapability(name: "deb_archive", state: .verified, detail: "ar/control.tar/data.tar inspected in memory; final file read back byte-for-byte"),
            VerificationCapability(name: "rootless_layout", state: .verified, detail: evidence.payloadPath),
            VerificationCapability(name: "fat_architectures", state: .verified, detail: universal.architectures.joined(separator: ",")),
            VerificationCapability(name: "signature", state: .notApplicable, detail: "build does not sign packages")
        ]
        return ArtifactVerificationResult(path: guestPath, kind: .deb, state: .available,
            exists: true, sizeBytes: Int64(published.bytes), sha256: published.sha256,
            archiveEntries: ["debian-binary", "control.tar", "data.tar", evidence.payloadPath,
                            metadata.payloadDirectory + "/" + metadata.tweakName + ".plist"],
            archiveEntryCount: 5, architectures: universal.architectures, encryption: nil,
            signature: "unsigned", debControl: control, rootlessPaths: true,
            rootlessViolations: [], capabilities: capabilities, errors: [])
    }

    // Evidence is intentionally limited to actual adapter samples: no inferred
    // process-lifetime baseline or fake complete log is reported.
    func reportMetadata(_ reports: [EmbeddedAdapterResult]) -> [String: String] {
        var fields = ["native_provider": "embedded_toolchain", "full_log_persisted": "false"]
        let samples = reports.flatMap(\.residentSamplesBytes)
        if let peak = samples.max() { fields["peak_observed_resident_bytes"] = String(peak) }
        if !reports.isEmpty {
            fields["resident_samples_by_architecture"] = reports.enumerated().map { index, report in
                (index == 0 ? "arm64=" : "arm64e=") + report.residentSamplesBytes.map(String.init).joined(separator: ",")
            }.joined(separator: ";")
        }
        if let last = reports.last { fields["process_link_count"] = String(last.processLinkCount) }
        for (index, report) in reports.enumerated() where index < 2 {
            let architecture = index == 0 ? "arm64" : "arm64e"
            fields[architecture + "_state"] = report.state
            fields[architecture + "_temporary_outputs_removed"] = String(report.temporaryOutputsRemoved)
            fields[architecture + "_process_link_count"] = String(report.processLinkCount)
            fields[architecture + "_resident_samples_bytes"] = report.residentSamplesBytes.map(String.init).joined(separator: ",")
            if let first = report.residentSamplesBytes.first, let peak = report.residentSamplesBytes.max() {
                fields[architecture + "_observed_growth_from_first_sample_bytes"] = String(peak > first ? peak - first : 0)
            }
        }
        return fields
    }

    func reportSummary(_ reports: [EmbeddedAdapterResult]) -> String {
        reports.enumerated().map { index, report in
            let architecture = index == 0 ? "arm64" : "arm64e"
            let steps = report.steps.map { "\($0.operation)=\($0.status)" }.joined(separator: ", ")
            return architecture + " [" + report.state + "; links=" + String(report.processLinkCount) +
                "; cleanup=" + String(report.temporaryOutputsRemoved) + "]: " + steps
        }.joined(separator: "\n")
    }

    func failedExecution(_ reason: String, runID: String, started: Date,
                         reports: [EmbeddedAdapterResult] = [],
                         extraMetadata: [String: String] = [:]) -> BuildProviderExecution {
        let stderr = reports.flatMap(\.steps).map(\.stderr).filter { !$0.isEmpty }.joined(separator: "\n")
        let firstError = BuildLogAnalyzer.analyze(stderr).firstError?.raw
        let bounded = String(stderr.prefix(6000))
        let excerpt = [firstError, bounded.isEmpty ? nil : bounded, String(reason.prefix(4000))]
            .compactMap { $0 }.joined(separator: "\n")
        let (safe, _) = EnvVarRedactor.redactIfEnabled(excerpt)
        var metadata = reportMetadata(reports)
        for (key, value) in extraMetadata { metadata[key] = value }
        return .completed(BuildCommandExecution(command: "embedded-toolchain structured build",
            exitCode: 1, durationSeconds: Date().timeIntervalSince(started), stdoutSummary: reportSummary(reports),
            stderrSummary: safe, fullLogPath: "", diagnosticExcerpt: safe,
            remoteMetadata: metadata, remoteJobs: [], remoteArtifacts: []))
    }
}
