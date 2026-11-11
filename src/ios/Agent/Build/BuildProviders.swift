import Foundation

@MainActor
protocol BuildProvider {
    var id: BuildProviderID { get }
    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability
    func resolvedToolchain(for context: BuildProviderContext) async -> String
    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution
    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution
}

@MainActor
enum BuildProviderRegistry {
    static let providers: [any BuildProvider] = [
        LocalISHBuildProvider(),
        TheosBuildProvider(),
        EmbeddedTheosBuildProvider(),
        RemoteGitHubActionsProvider(),
        MacSSHBuildProvider(),
        EmbeddedToolchainBuildProvider(),
    ]

    static func provider(_ id: BuildProviderID) -> (any BuildProvider)? {
        providers.first { $0.id == id }
    }
}

@MainActor
struct LocalISHBuildProvider: BuildProvider {
    let id: BuildProviderID = .localISH

    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability {
        let command = context.request.command
            ?? context.inspection.suggestedCommands.first(where: { $0.provider == id && $0.purpose == "build" })?.command
        let executable = requiredExecutable(command: command, kind: context.inspection.kind)
        let probe: String
        if let executable {
            probe = "command -v \(ShellEscaping.singleQuote(executable)) >/dev/null 2>&1"
        } else {
            probe = "test -x /bin/sh"
        }
        let available = (try? await context.executor(probe, 10).exitCode) == 0
        return BuildProviderAvailability(
            provider: id,
            state: available ? .available : .unavailable,
            reason: available ? "iSH shell and required local tool are available." : "Required iSH executable is unavailable.",
            missingConfiguration: available ? [] : [executable ?? "/bin/sh"],
            capabilities: ["local commands", "captured exit code", "separate stdout/stderr logs"]
        )
    }

    func resolvedToolchain(for context: BuildProviderContext) async -> String {
        let executable = requiredExecutable(command: context.request.command, kind: context.inspection.kind)
        let version = executable.map { "\(ShellEscaping.singleQuote($0)) --version 2>/dev/null | head -2" } ?? "true"
        let probe = "{ uname -srm 2>/dev/null; \(version); } | tr '\\n' ' '"
        let result = try? await context.executor(probe, 10)
        let value = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return "local-ish:" + String(value.prefix(512))
    }

    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        guard availability.isAvailable else { return .unavailable(availability) }
        let command: String
        if let explicit = context.request.command {
            command = explicit
        } else if let inferred = context.inspection.suggestedCommands.first(where: { $0.provider == id && $0.purpose == "build" })?.command {
            command = BuildCommandPolicy.applying(configuration: context.request.configuration, to: inferred)
        } else {
            return .unavailable(.init(provider: id, state: .unavailable, reason: "No build command was supplied or inferred.", missingConfiguration: ["command"], capabilities: availability.capabilities))
        }
        return await BuildCommandRunner.run(
            projectPath: context.inspection.canonicalPath,
            command: command,
            displayCommand: CredentialLogPolicy.redact(command),
            runID: runID,
            phase: "build",
            timeout: context.request.timeoutSeconds,
            executor: context.executor
        )
    }

    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        guard availability.isAvailable else { return .unavailable(availability) }
        guard let command = context.request.testCommand
            ?? context.inspection.suggestedCommands.first(where: { $0.provider == id && $0.purpose == "test" })?.command else {
            return .unavailable(.init(provider: id, state: .unavailable, reason: "No test command was supplied or inferred.", missingConfiguration: ["test_command"], capabilities: availability.capabilities))
        }
        return await BuildCommandRunner.run(
            projectPath: context.inspection.canonicalPath,
            command: command,
            displayCommand: CredentialLogPolicy.redact(command),
            runID: runID,
            phase: "tests",
            timeout: context.request.timeoutSeconds,
            executor: context.executor
        )
    }

    private func requiredExecutable(command: String?, kind: ProjectBuildKind) -> String? {
        let text = command?.lowercased() ?? ""
        for executable in ["xcodebuild", "swift", "cargo", "cmake", "gradle", "npm", "make"] where text.contains(executable) {
            return executable == "gradle" && text.contains("./gradlew") ? nil : executable
        }
        switch kind {
        case .xcode: return "xcodebuild"
        case .swiftPackage: return "swift"
        case .cargo: return "cargo"
        case .cmake: return "cmake"
        case .make, .theos: return "make"
        case .embeddedTweak, .node, .gradle, .mixed, .unknown: return nil
        }
    }
}

@MainActor
struct TheosBuildProvider: BuildProvider {
    let id: BuildProviderID = .theos

    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability {
        let command = "test -d \"${THEOS:-/opt/theos}\" && command -v make >/dev/null 2>&1"
        let available = (try? await context.executor(command, 10).exitCode) == 0
        return BuildProviderAvailability(
            provider: id,
            state: available ? .available : .unavailable,
            reason: available ? "Theos and make are available in iSH." : "Theos is not installed at $THEOS or /opt/theos, or make is missing.",
            missingConfiguration: available ? [] : ["THEOS directory (/opt/theos by default)", "make"],
            capabilities: ["Theos makefiles", "package (.deb)", "rootless layout verification"]
        )
    }

    func resolvedToolchain(for context: BuildProviderContext) async -> String {
        let probe = "{ printf 'theos='; test -d \"${THEOS:-/opt/theos}\" && git -C \"${THEOS:-/opt/theos}\" rev-parse HEAD 2>/dev/null || printf unknown; printf ' '; make --version 2>/dev/null | head -1; ${CC:-clang} --version 2>/dev/null | head -1; } | tr '\\n' ' '"
        let result = try? await context.executor(probe, 10)
        return "theos:" + String((result?.output ?? "unknown").prefix(512))
    }

    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        guard availability.isAvailable else { return .unavailable(availability) }
        let command = context.request.command ?? "make package"
        return await BuildCommandRunner.run(projectPath: context.inspection.canonicalPath, command: command, displayCommand: CredentialLogPolicy.redact(command), runID: runID, phase: "build", timeout: context.request.timeoutSeconds, executor: context.executor)
    }

    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        guard availability.isAvailable else { return .unavailable(availability) }
        guard let command = context.request.testCommand else {
            return .unavailable(.init(provider: id, state: .unavailable, reason: "Theos has no universal test target; pass test_command explicitly.", missingConfiguration: ["test_command"], capabilities: availability.capabilities))
        }
        return await BuildCommandRunner.run(projectPath: context.inspection.canonicalPath, command: command, displayCommand: CredentialLogPolicy.redact(command), runID: runID, phase: "tests", timeout: context.request.timeoutSeconds, executor: context.executor)
    }
}

@MainActor
struct EmbeddedTheosBuildProvider: BuildProvider {
    let id: BuildProviderID = .embeddedTheos

    private let capabilities = [
        "Twork-level in-process Clang/LLVM and ld64 target",
        "real iPhoneOS SDK and framework header resolution",
        "multi-target Theos graph: daemon and/or tweak",
        "arm64 and arm64e native Mach-O outputs",
        "rootless DEB staging and independent verification"
    ]

    private struct PreparedRequest: Sendable {
        let root: URL
        let project: EmbeddedTheosProjectPlan
        let plans: [EmbeddedTheosTargetPlan]
        let control: EmbeddedTheosControlMetadata
        let filterPlist: Data?
        let layout: [EmbeddedTheosLayoutEntry]
        let artifactGuestPath: String
    }

    private struct PackagedDelivery: Sendable {
        let deb: Data
        let architectures: [String]
        let payloadPaths: [String]
        let targetKinds: [String]
        let signingRequirements: [EmbeddedTheosSigningRequirement]
        let signedSlices: [EmbeddedTheosSignedSlice]
    }

    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability {
        do {
            _ = try prepare(context)
        } catch {
            return unavailable(error.localizedDescription,
                ["declarative rootless Theos project under the active session workspace"])
        }
        return toolchainAvailability()
    }

    /// Declarative preflight: it reads the Makefile, the `control` file, the tweak
    /// filter plist and the `layout/` tree, then plans typed compile actions. It
    /// never runs a recipe, hook or command.
    private func prepare(_ context: BuildProviderContext) throws -> PreparedRequest {
        guard context.inspection.kind == .theos else {
            throw EmbeddedAdapterError.rejected("embedded_theos requires a detected Theos project")
        }
        guard context.request.command == nil && context.request.testCommand == nil else {
            throw EmbeddedAdapterError.rejected("embedded_theos accepts no shell command or test command")
        }
        guard let workspace = context.nativeWorkspaceRoot else {
            throw EmbeddedAdapterError.rejected("the active chat session has no native workspace URL")
        }
        let root = try Self.resolveWorkspaceProject(context.request.projectPath, workspace: workspace)
        let makefile = try Self.readBoundedMakefile(root)
        let inspection = try EmbeddedTheosManifestParser.inspect(makefile: makefile)
        // Every recipe and hook is reported by the parser and deliberately not run.
        // Anything beyond the default `all` target would change the staged package,
        // so the build fails instead of silently shipping an incomplete DEB.
        let blocked = inspection.ignoredRecipes.filter { $0 != "all::" && $0 != "all:" }
        guard blocked.isEmpty else {
            let detail = blocked.prefix(8).joined(separator: " | ")
            throw EmbeddedAdapterError.rejected(
                "the native adapter never executes Makefile recipes or package hooks; move that staging into layout/ and delete: \(detail)")
        }
        let control = try Self.readControl(root)
        var filterPlist: Data?
        var bundleIDs: [String] = []
        if let tweak = inspection.targets.first(where: { $0.kind == .tweak }),
           let filterPath = tweak.filterPlistPath {
            guard let data = try? EmbeddedToolchainProjectSnapshotBuilder.readBoundedProjectFile(
                filterPath, root: root, limit: EmbeddedTheosFilterPlist.maxBytes) else {
                throw EmbeddedAdapterError.rejected("Theos tweak must ship \(filterPath) declaring Filter.Bundles")
            }
            filterPlist = data
            bundleIDs = try EmbeddedTheosFilterPlist.bundleIDs(from: data)
        }
        let project = EmbeddedTheosProjectPlan(schema: 1, packageID: control.packageID,
            version: control.version, name: control.name, maintainer: control.maintainer,
            description: control.description, bundleIDs: bundleIDs, targets: inspection.targets)
        try project.validate()
        var declared = inspection.targets.flatMap { $0.sourcePaths + $0.headerPaths }
        declared.append(contentsOf: inspection.targets.compactMap(\.entitlementsPath))
        declared.append(contentsOf: inspection.targets.compactMap(\.filterPlistPath))
        let contents = try EmbeddedToolchainProjectSnapshotBuilder.loadDeclaredTheosFiles(
            Array(Set(declared)).sorted(), root: root)
        let plans = try EmbeddedTheosCompilePlanner.plan(project: project, fileContents: contents)
        let layout = try EmbeddedTheosLayoutLoader.load(root: root)
        let guestOutput = "\(context.request.projectPath)/\(EmbeddedToolchainProjectPublisher.outputDirectory)/\(control.filename)"
        if !context.request.artifactPaths.isEmpty && context.request.artifactPaths != [guestOutput] {
            throw EmbeddedAdapterError.rejected("artifact_paths, when supplied, must name the generated DEB inside this project")
        }
        return PreparedRequest(root: root, project: project, plans: plans, control: control,
                               filterPlist: filterPlist, layout: layout, artifactGuestPath: guestOutput)
    }

    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let started = Date()
        let cancellation = EmbeddedAdapterCancellation()
        return await withTaskCancellationHandler {
            do {
                guard !cancellation.isCancelled else { throw CancellationError() }
                let ready = await availability(for: context)
                guard !cancellation.isCancelled else { throw CancellationError() }
                guard ready.isAvailable else { return .unavailable(ready) }
                let prepared = try prepare(context)
                guard !cancellation.isCancelled else { throw CancellationError() }
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try EmbeddedTheosExecutor.execute(plans: prepared.plans, cancellation: cancellation)
                }.value
                guard !cancellation.isCancelled else { throw CancellationError() }
                guard outcome.passed else {
                    return failedExecution(outcome.failure ?? "the in-process Theos adapter produced no verified output",
                                           runID: runID, started: started, outcome: outcome)
                }
                let delivery = try Self.package(outcome: outcome, prepared: prepared)
                let published = try await Task.detached(priority: .userInitiated) {
                    try EmbeddedToolchainProjectPublisher.publishVerifiedTheosDeb(
                        delivery.deb, named: prepared.control.filename, projectRoot: prepared.root,
                        verification: { _ = try EmbeddedTheosDebPackage.verifySignatures(
                            delivery.deb, requirements: delivery.signingRequirements) },
                        cancellation: cancellation)
                }.value
                // A committed rename wins a concurrent late cancellation; the publisher
                // has already read the committed directory entry back byte-for-byte.
                guard published.sha256 == EmbeddedAdapterArtifact.digest(delivery.deb),
                      published.bytes == delivery.deb.count else {
                    return failedExecution("published DEB does not match the verified in-memory package",
                                           runID: runID, started: started, outcome: outcome)
                }
                var metadata: [String: String] = ["native_provider": "embedded_theos",
                                                  "full_log_persisted": "false",
                                                  "artifact_path": prepared.artifactGuestPath,
                                                  "artifact_sha256": published.sha256,
                                                  "targets": delivery.targetKinds.joined(separator: ","),
                                                  "payload_paths": delivery.payloadPaths.joined(separator: ";")]
                metadata["artifact_bytes"] = String(published.bytes)
                metadata["directory_synced"] = String(published.directorySynced)
                metadata["layout_files"] = String(prepared.layout.count)
                metadata["compile_attempts"] = String(outcome.attempts)
                metadata["link_count"] = String(outcome.linkCount)
                metadata["payload_signature"] = "adhoc"
                metadata["signed_slices"] = String(delivery.signedSlices.count)
                let execution = BuildCommandExecution(
                    command: "embedded-theos: \(delivery.architectures.joined(separator: " + ")) -> rootless DEB", exitCode: 0,
                    durationSeconds: Date().timeIntervalSince(started),
                    stdoutSummary: Self.summary(outcome: outcome, delivery: delivery),
                    stderrSummary: "", fullLogPath: "", diagnosticExcerpt: "",
                    remoteMetadata: metadata, remoteJobs: [], remoteArtifacts: [])
                return .completedWithArtifacts(execution, [Self.verifiedDEB(published, delivery: delivery,
                    control: prepared.control, guestPath: prepared.artifactGuestPath)])
            } catch {
                if let publisherError = error as? EmbeddedToolchainProjectPublisherError,
                   case let .committedButUnverified(_, directorySynced) = publisherError {
                    return failedExecution(error.localizedDescription, runID: runID, started: started,
                        outcome: nil, extraMetadata: ["publication_committed": "true",
                                                      "directory_synced": String(directorySynced)])
                }
                return failedExecution(error is CancellationError ? "cancelled before publication" : error.localizedDescription,
                    runID: runID, started: started, outcome: nil)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        return .unavailable(.init(provider: id, state: .unavailable,
            reason: "embedded_theos compiles and packages a rootless DEB but never runs generated code or tests on device.",
            missingConfiguration: ["separate authorized device test workflow"],
            capabilities: availability.capabilities))
    }

    func resolvedToolchain(for context: BuildProviderContext) async -> String {
        let status = OMToolchain.capabilityStatus()
        let fields = ["compiler_linked", "verification", "state", "host_architecture", "resource_headers", "sdk"]
            .compactMap { key in status[key].map { "\(key)=\($0)" } }
            .joined(separator: " ")
        return "embedded-theos: " + fields
    }

    private func toolchainAvailability() -> BuildProviderAvailability {
        let status = OMToolchain.capabilityStatus()
        let required: [(String, String)] = [
            ("compiler_linked", "yes"), ("verification", "passed"),
            ("resource_headers", "present"), ("sdk", "present"), ("state", "ready")
        ]
        let missing = required.compactMap { key, value in status[key] == value ? nil : key + "=" + value }
        guard status["host_architecture"] == "arm64" || status["host_architecture"] == "arm64e" else {
            return unavailable("The in-process compiler host architecture is unsupported.",
                               missing + ["arm64 or arm64e host"])
        }
        guard missing.isEmpty else {
            return unavailable("The verified in-process compiler or pinned SDK is not ready; nothing was compiled and no Makefile recipe ran.",
                               missing)
        }
        return BuildProviderAvailability(provider: id, state: .available,
            reason: "The session-workspace Theos project passes the declarative native preflight.",
            missingConfiguration: [], capabilities: capabilities)
    }

    private static func readControl(_ root: URL) throws -> EmbeddedTheosControlMetadata {
        let data = try EmbeddedToolchainProjectSnapshotBuilder.readBoundedProjectFile(
            "control", root: root, limit: EmbeddedTheosControlMetadata.maxBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EmbeddedAdapterError.rejected("the Theos control file must be bounded UTF-8")
        }
        return try EmbeddedTheosControlMetadata.parse(text)
    }

    /// Preserves a single target slice or merges two verified slices, then
    /// assembles the rootless payload. Nothing is written, signed or executed here.
    private static func package(outcome: EmbeddedTheosExecutionOutcome,
                                prepared: PreparedRequest) throws -> PackagedDelivery {
        var slicesByTarget: [String: [String: EmbeddedTheosBuiltArtifact]] = [:]
        let expectedTargets = Set(prepared.project.targets.map(\.name))
        for artifact in outcome.artifacts {
            guard expectedTargets.contains(artifact.targetName),
                  slicesByTarget[artifact.targetName]?[artifact.architecture] == nil else {
                throw EmbeddedAdapterError.rejected("unexpected or duplicate Theos target slice")
            }
            slicesByTarget[artifact.targetName, default: [:]][artifact.architecture] = artifact
        }
        var entries: [EmbeddedTheosDebEntry] = []
        var architectures: [String] = []
        var payloadPaths: [String] = []
        var kinds: [String] = []
        var requirements: [EmbeddedTheosSigningRequirement] = []
        for target in prepared.project.targets {
            try target.validate()
            guard let byArchitecture = slicesByTarget[target.name],
                  Set(byArchitecture.keys) == Set(target.architectures.map(\.rawValue)) else {
                throw EmbeddedAdapterError.rejected("Theos slices differ from declared ARCHS: \(target.name)")
            }
            let slices = try target.architectures.map { arch -> Data in
                guard let artifact = byArchitecture[arch.rawValue] else {
                    throw EmbeddedAdapterError.rejected("Theos target slice is missing: \(target.name)")
                }
                return artifact.data
            }
            let filetype = target.kind == .tweak
                ? EmbeddedUniversalFileType.dylib.rawValue : EmbeddedUniversalFileType.executable.rawValue
            let containerName = target.kind == .tweak ? target.name + ".dylib" : target.name
            let payload: Data
            if slices.count == 1 {
                payload = slices[0]
            } else {
                payload = try EmbeddedToolchainUniversalBinary.merge(
                    arm64: slices[0], arm64e: slices[1], name: containerName, filetype: filetype)
            }
            let verified = try EmbeddedToolchainUniversalBinary.inspectPayload(payload,
                name: containerName, filetype: filetype, expectedArchitectures: target.architectures)
            let foundArchitectures = Set(architectures + verified.architectures)
            architectures = ["arm64", "arm64e"].filter { foundArchitectures.contains($0) }
            let installed = EmbeddedTheosDebPackage.rootlessPrefix + target.installPath
            entries.append(EmbeddedTheosDebEntry(path: installed, bytes: payload, mode: 0o755))
            payloadPaths.append(installed)
            requirements.append(EmbeddedTheosSigningRequirement(path: installed, name: containerName,
                filetype: filetype,
                entitlements: prepared.plans.first { $0.target.name == target.name }?.entitlements,
                architectures: target.architectures))
            kinds.append("\(target.name):\(target.kind.rawValue):\(verified.architectures.joined(separator: "+"))")
            if target.kind == .tweak {
                guard let filter = prepared.filterPlist else {
                    throw EmbeddedAdapterError.rejected("Theos tweak has no verified filter plist: \(target.name)")
                }
                let installedFilter = EmbeddedTheosDebPackage.rootlessPrefix +
                    "Library/MobileSubstrate/DynamicLibraries/" + target.name + ".plist"
                entries.append(EmbeddedTheosDebEntry(path: installedFilter, bytes: filter, mode: 0o644))
                payloadPaths.append(installedFilter)
            }
        }
        for layout in prepared.layout {
            let installed = EmbeddedTheosDebPackage.rootlessPrefix + layout.path
            guard !payloadPaths.contains(installed) else {
                throw EmbeddedAdapterError.rejected("layout file collides with a generated output: \(layout.path)")
            }
            entries.append(EmbeddedTheosDebEntry(path: installed, bytes: layout.bytes, mode: layout.mode))
            payloadPaths.append(installed)
        }
        let deb = try EmbeddedTheosDebPackage.build(files: entries, controlText: prepared.control.controlText)
        _ = try EmbeddedTheosDebPackage.inspect(deb)
        let signedSlices = try EmbeddedTheosDebPackage.verifySignatures(deb, requirements: requirements)
        let expectedSignedSlices = requirements.reduce(0) { $0 + $1.architectures.count }
        guard signedSlices.count == expectedSignedSlices,
              Set(signedSlices.map { "\($0.path)|\($0.architecture)" }).count == signedSlices.count else {
            throw EmbeddedAdapterError.rejected("final DEB signature evidence is incomplete")
        }
        return PackagedDelivery(deb: deb, architectures: architectures, payloadPaths: payloadPaths,
            targetKinds: kinds, signingRequirements: requirements, signedSlices: signedSlices)
    }

    private static func summary(outcome: EmbeddedTheosExecutionOutcome, delivery: PackagedDelivery) -> String {
        let targetKinds = delivery.targetKinds.joined(separator: ",")
        let payloadFiles = delivery.payloadPaths.count
        return "targets=\(targetKinds); compile_units=\(outcome.attempts); links=\(outcome.linkCount); payload_files=\(payloadFiles); temporary_outputs_removed=\(outcome.temporaryOutputsRemoved)"
    }

    private static func verifiedDEB(_ published: EmbeddedToolchainPublishedArtifact,
                                    delivery: PackagedDelivery, control: EmbeddedTheosControlMetadata,
                                    guestPath: String) -> ArtifactVerificationResult {
        let debControl = ["Package": control.packageID, "Name": control.name, "Version": control.version,
                          "Architecture": "iphoneos-arm64", "Maintainer": control.maintainer,
                          "Description": control.description, "Section": "Tweaks", "Priority": "optional",
                          "Depends": control.depends]
        let capabilities = [
            VerificationCapability(name: "sha256", state: .verified, detail: "final file readback: " + published.sha256),
            VerificationCapability(name: "deb_archive", state: .verified, detail: "ar/control.tar/data.tar inspected in memory; final file read back byte-for-byte"),
            VerificationCapability(name: "rootless_layout", state: .verified, detail: delivery.payloadPaths.joined(separator: ",")),
            VerificationCapability(name: "macho_architectures", state: .verified, detail: delivery.architectures.joined(separator: ",")),
            VerificationCapability(name: "payload_signature", state: .verified,
                detail: "generated Mach-O payloads verified ad-hoc: " + delivery.signedSlices
                    .map { "\($0.path)#\($0.architecture)(\($0.codeSlots) slots)" }.joined(separator: ",")),
            VerificationCapability(name: "deb_container_signature", state: .notApplicable,
                detail: "the .deb container itself is not CMS or debsig signed; only its Mach-O payloads carry signatures")
        ]
        return ArtifactVerificationResult(path: guestPath, kind: .deb, state: .available,
            exists: true, sizeBytes: Int64(published.bytes), sha256: published.sha256,
            archiveEntries: ["debian-binary", "control.tar", "data.tar"] + delivery.payloadPaths,
            archiveEntryCount: delivery.payloadPaths.count + 3, architectures: delivery.architectures,
            encryption: nil, signature: "ad-hoc (generated Mach-O payloads only)", debControl: debControl,
            rootlessPaths: true, rootlessViolations: [], capabilities: capabilities, errors: [])
    }

    private func failedExecution(_ reason: String, runID: String, started: Date,
                                 outcome: EmbeddedTheosExecutionOutcome?,
                                 extraMetadata: [String: String] = [:]) -> BuildProviderExecution {
        var metadata = ["native_provider": "embedded_theos", "full_log_persisted": "false"]
        if let outcome = outcome {
            metadata["compile_attempts"] = String(outcome.attempts)
            metadata["link_count"] = String(outcome.linkCount)
            metadata["temporary_outputs_removed"] = String(outcome.temporaryOutputsRemoved)
            metadata["built_artifacts"] = String(outcome.artifacts.count)
        }
        for (key, value) in extraMetadata { metadata[key] = value }
        let bounded = String(reason.prefix(4000))
        return .completed(BuildCommandExecution(command: "embedded-theos structured build", exitCode: 1,
            durationSeconds: Date().timeIntervalSince(started), stdoutSummary: "",
            stderrSummary: bounded, fullLogPath: "", diagnosticExcerpt: bounded,
            remoteMetadata: metadata, remoteJobs: [], remoteArtifacts: []))
    }

    /// Resolves the same workspace-confined project root used by the restricted
    /// provider, so embedded_theos never reads outside the active session folder.
    private static func resolveWorkspaceProject(_ guestPath: String, workspace: URL) throws -> URL {
        try EmbeddedToolchainProjectSnapshotBuilder.resolveWorkspaceProject(
            guestPath: guestPath, workspace: workspace)
    }

    /// Reads only a bounded, symlink-free regular Makefile from the project root.
    private static func readBoundedMakefile(_ root: URL) throws -> String {
        let url = root.appendingPathComponent("Makefile")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw EmbeddedAdapterError.rejected("Makefile is missing or unsafe") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= off_t(EmbeddedTheosManifestParser.maxBytes) else {
            throw EmbeddedAdapterError.rejected("Makefile is not a bounded regular file")
        }
        let data = try handle.read(upToCount: EmbeddedTheosManifestParser.maxBytes + 1) ?? Data()
        guard data.count == Int(attributes.st_size), let text = String(data: data, encoding: .utf8) else {
            throw EmbeddedAdapterError.rejected("Makefile is not bounded UTF-8")
        }
        return text
    }

    private func unavailable(_ reason: String, _ missing: [String]) -> BuildProviderAvailability {
        BuildProviderAvailability(provider: id, state: .unavailable, reason: reason,
                                  missingConfiguration: missing, capabilities: capabilities)
    }
}

@MainActor
struct RemoteGitHubActionsProvider: BuildProvider {
    let id: BuildProviderID = .remoteGitHubActions

    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability {
        let probe = "command -v gh >/dev/null 2>&1 || exit 20; { test -n \"${GH_TOKEN:-}\" || test -n \"${GITHUB_TOKEN:-}\" || gh auth status >/dev/null 2>&1; } || exit 21; git -C \(ShellEscaping.singleQuote(context.inspection.canonicalPath)) remote get-url origin >/dev/null 2>&1 || exit 22"
        let result = try? await context.executor(probe, 15)
        let code = result?.exitCode ?? -1
        let missing: [String]
        let reason: String
        switch code {
        case 0:
            missing = []
            reason = "GitHub CLI authentication and repository remote are configured."
        case 20:
            missing = ["gh executable"]
            reason = "GitHub CLI is not installed."
        case 21:
            missing = ["GH_TOKEN or GITHUB_TOKEN, or gh auth login"]
            reason = "GitHub authentication is not configured; no credential value was read."
        case 22:
            missing = ["git remote origin"]
            reason = "The project has no origin remote."
        default:
            missing = ["GitHub Actions configuration"]
            reason = "GitHub Actions availability probe failed."
        }
        return BuildProviderAvailability(
            provider: id,
            state: code == 0 ? .available : .unavailable,
            reason: reason,
            missingConfiguration: missing,
            capabilities: ["workflow_dispatch", "real run id and run number", "job conclusion", "artifact metadata without artifact download"]
        )
    }

    func resolvedToolchain(for context: BuildProviderContext) async -> String {
        let workflow = resolvedWorkflow(context)
        let command = "cd \(ShellEscaping.singleQuote(context.inspection.canonicalPath)) && { printf 'github-actions:'; git hash-object \(ShellEscaping.singleQuote(workflow)) 2>/dev/null || printf unknown; }"
        let result = try? await context.executor(command, 10)
        return (result?.output.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "github-actions:unknown"
    }

    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        guard availability.isAvailable else { return .unavailable(availability) }
        let workflow = resolvedWorkflow(context)
        guard !workflow.isEmpty else {
            return .unavailable(.init(provider: id, state: .unavailable, reason: "No workflow was supplied or found.", missingConfiguration: ["workflow"], capabilities: availability.capabilities))
        }
        for key in context.request.workflowInputs.keys where CredentialLogPolicy.isSensitiveName(key) {
            return .unavailable(.init(provider: id, state: .unavailable, reason: "Sensitive workflow inputs are refused; configure Actions secrets in GitHub instead.", missingConfiguration: ["non-sensitive workflow input: \(key)"], capabilities: availability.capabilities))
        }
        let command = githubCommand(workflow: workflow, inputs: context.request.workflowInputs)
        return await BuildCommandRunner.run(
            projectPath: context.inspection.canonicalPath,
            command: command,
            displayCommand: "gh workflow run \(workflow); discover exact run id; gh run watch --exit-status",
            runID: runID,
            phase: "github-actions",
            timeout: context.request.timeoutSeconds,
            executor: context.executor
        )
    }

    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        // A remote workflow is one authoritative job. Its zero exit code can be
        // recorded as build success, but not as tests passed unless the caller
        // explicitly requested a dedicated test workflow.
        guard context.request.testCommand != nil else {
            let availability = await availability(for: context)
            return .unavailable(.init(provider: id, state: .unavailable, reason: "Pass a dedicated test workflow in test_command; a build workflow does not prove tests passed.", missingConfiguration: ["test_command workflow filename"], capabilities: availability.capabilities))
        }
        var request = context.request
        request = BuildRequest(projectPath: request.projectPath, provider: request.provider, configuration: request.configuration, toolchain: request.toolchain, command: request.command, testCommand: request.testCommand, artifactPaths: request.artifactPaths, timeoutSeconds: request.timeoutSeconds, cachePolicy: request.cachePolicy, attempt: request.attempt, maxAttempts: request.maxAttempts, workflow: request.testCommand, workflowInputs: request.workflowInputs)
        return await build(context: .init(inspection: context.inspection, request: request, executor: context.executor), runID: runID + "-tests")
    }

    private func resolvedWorkflow(_ context: BuildProviderContext) -> String {
        context.request.workflow
            ?? context.inspection.suggestedCommands.first(where: { $0.provider == id && $0.purpose == "build" })?.command
            ?? ""
    }

    private func githubCommand(workflow: String, inputs: [String: String]) -> String {
        let flags = inputs.sorted(by: { $0.key < $1.key }).map { key, value in
            "-f \(ShellEscaping.singleQuote(key + "=" + value))"
        }.joined(separator: " ")
        return """
        set +x
        remote="$(git remote get-url origin 2>/dev/null)" || exit 31
        repo="$(printf '%s' "$remote" | sed -E 's#^https?://[^/]+/##; s#^[^@]+@[^:]+:##; s#\\.git$##')"
        test -n "$repo" || exit 31
        ref="$(git rev-parse --abbrev-ref HEAD)" || exit 32
        sha="$(git rev-parse HEAD)" || exit 32
        prior="$(gh run list --repo "$repo" --workflow \(ShellEscaping.singleQuote(workflow)) --branch "$ref" --limit 30 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)"
        gh workflow run \(ShellEscaping.singleQuote(workflow)) --repo "$repo" --ref "$ref" \(flags) || exit 33
        run_id=""
        i=0
        while test "$i" -lt 30; do
          current="$(gh run list --repo "$repo" --workflow \(ShellEscaping.singleQuote(workflow)) --branch "$ref" --event workflow_dispatch --limit 30 --json databaseId,headSha --jq '.[] | select(.headSha == "'"$sha"'") | .databaseId' 2>/dev/null || true)"
          for candidate in $current; do
            if ! printf '%s\\n' "$prior" | grep -qx "$candidate"; then run_id="$candidate"; break; fi
          done
          test -n "$run_id" && break
          i=$((i+1)); sleep 2
        done
        test -n "$run_id" || { printf '%s\\n' 'GitHub dispatch accepted but exact run id was not discovered.' >&2; exit 34; }
        gh run view "$run_id" --repo "$repo" --json databaseId,number,status,conclusion,url,workflowName,headSha --jq '"__MINIS_REMOTE__run_id="+(.databaseId|tostring)+" run_number="+(.number|tostring)+" status="+.status+" conclusion="+(.conclusion//"")+" run_url="+.url+" workflow="+.workflowName+" head_sha="+.headSha'
        gh run watch "$run_id" --repo "$repo" --exit-status
        watch_rc=$?
        gh api "repos/$repo/actions/runs/$run_id" --jq '"__MINIS_REMOTE__run_id="+(.id|tostring)+" run_number="+(.run_number|tostring)+" status="+.status+" conclusion="+(.conclusion//"")+" run_url="+.html_url+" run_logs_url="+.logs_url+" jobs_url="+.jobs_url+" artifacts_url="+.artifacts_url+" repository="+.repository.full_name+" head_sha="+.head_sha'
        gh api "repos/$repo/actions/runs/$run_id/jobs" --jq '.jobs[]? | "__MINIS_JOB__id="+(.id|tostring)+" name="+.name+" status="+.status+" conclusion="+(.conclusion//"")+" html_url="+.html_url+" api_url="+.url' || true
        gh api "repos/$repo/actions/runs/$run_id/artifacts" --jq '.artifacts[]? | "__MINIS_ARTIFACT__id="+(.id|tostring)+" name="+.name+" size="+(.size_in_bytes|tostring)+" expired="+(.expired|tostring)+" url="+.archive_download_url' || true
        exit "$watch_rc"
        """
    }
}

@MainActor
struct MacSSHBuildProvider: BuildProvider {
    let id: BuildProviderID = .macSSH

    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability {
        let probe = "command -v ssh >/dev/null 2>&1 || exit 40; test -n \"${MINIS_MAC_SSH_HOST:-}\" || exit 41; test -n \"${MINIS_MAC_PROJECT_PATH:-}\" || exit 42; target=\"${MINIS_MAC_SSH_USER:+$MINIS_MAC_SSH_USER@}$MINIS_MAC_SSH_HOST\"; ssh -o BatchMode=yes -o ConnectTimeout=8 \"$target\" 'command -v xcodebuild >/dev/null 2>&1' >/dev/null 2>&1 || exit 43"
        let code = (try? await context.executor(probe, 15).exitCode) ?? -1
        let missing: [String]
        let reason: String
        switch code {
        case 0: missing = []; reason = "Configured macOS SSH host is reachable and has xcodebuild."
        case 40: missing = ["ssh executable"]; reason = "SSH client is unavailable."
        case 41: missing = ["MINIS_MAC_SSH_HOST"]; reason = "macOS SSH host is not configured; no key was read."
        case 42: missing = ["MINIS_MAC_PROJECT_PATH"]; reason = "Remote project path is not configured; no key was read."
        case 43: missing = ["BatchMode SSH access and remote xcodebuild"]; reason = "Configured host was not reachable without interaction, or xcodebuild is missing. SSH key material was not read."
        default: missing = ["macOS SSH configuration"]; reason = "macOS SSH availability probe failed."
        }
        return BuildProviderAvailability(provider: id, state: code == 0 ? .available : .unavailable, reason: reason, missingConfiguration: missing, capabilities: ["real macOS xcodebuild", "BatchMode SSH", "remote exit status"])
    }

    func resolvedToolchain(for context: BuildProviderContext) async -> String {
        let command = sshCommand(remoteCommand: "{ xcodebuild -version; swift --version; uname -m; } 2>&1 | head -8")
        let result = try? await context.executor(command, 20)
        return "mac-ssh:" + String((result?.output ?? "unknown").prefix(512))
    }

    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        guard availability.isAvailable else { return .unavailable(availability) }
        let command: String
        if let explicit = context.request.command {
            command = explicit
        } else if let inferred = context.inspection.suggestedCommands.first(where: { $0.provider == id && $0.purpose == "build" })?.command {
            command = BuildCommandPolicy.applying(configuration: context.request.configuration, to: inferred)
        } else {
            return .unavailable(.init(provider: id, state: .unavailable, reason: "No xcodebuild command was supplied or inferred.", missingConfiguration: ["command"], capabilities: availability.capabilities))
        }
        let remote = sshCommand(remoteCommand: command)
        return await BuildCommandRunner.run(projectPath: context.inspection.canonicalPath, command: remote, displayCommand: "ssh $MINIS_MAC_SSH_HOST <remote build command>", runID: runID, phase: "mac-build", timeout: context.request.timeoutSeconds, executor: context.executor)
    }

    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        let availability = await availability(for: context)
        guard availability.isAvailable else { return .unavailable(availability) }
        guard let command = context.request.testCommand else {
            return .unavailable(.init(provider: id, state: .unavailable, reason: "No remote test command was supplied.", missingConfiguration: ["test_command"], capabilities: availability.capabilities))
        }
        return await BuildCommandRunner.run(projectPath: context.inspection.canonicalPath, command: sshCommand(remoteCommand: command), displayCommand: "ssh $MINIS_MAC_SSH_HOST <remote test command>", runID: runID, phase: "mac-tests", timeout: context.request.timeoutSeconds, executor: context.executor)
    }

    private func sshCommand(remoteCommand: String) -> String {
        let payload = Data(remoteCommand.utf8).base64EncodedString()
        return """
        set +x
        target="${MINIS_MAC_SSH_USER:+$MINIS_MAC_SSH_USER@}$MINIS_MAC_SSH_HOST"
        escaped_path="$(printf '%s' "$MINIS_MAC_PROJECT_PATH" | sed "s/'/'\\\\''/g")"
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "cd '$escaped_path' && printf %s \(ShellEscaping.singleQuote(payload)) | /usr/bin/base64 -D | /bin/zsh"
        """
    }
}

@MainActor
enum BuildCommandRunner {
    static func run(
        projectPath: String,
        command: String,
        displayCommand: String,
        runID: String,
        phase: String,
        timeout: Int,
        executor: BuildShellExecutor
    ) async -> BuildProviderExecution {
        let directory = "/var/minis/offloads/build-runs/\(runID)"
        let stdoutRaw = "\(directory)/\(phase).stdout.raw"
        let stderrRaw = "\(directory)/\(phase).stderr.raw"
        let stdoutLog = "\(directory)/\(phase).stdout.log"
        let stderrLog = "\(directory)/\(phase).stderr.log"
        let fullLog = "\(directory)/\(phase).log"
        let script = """
        set +x
        mkdir -p \(ShellEscaping.singleQuote(directory)) || exit 70
        start="$(date +%s)"
        (cd \(ShellEscaping.singleQuote(projectPath)) && /bin/sh -lc \(ShellEscaping.singleQuote(command))) >\(ShellEscaping.singleQuote(stdoutRaw)) 2>\(ShellEscaping.singleQuote(stderrRaw))
        command_rc=$?
        end="$(date +%s)"
        sanitize_log() {
          awk '{ lower=tolower($0); if (lower ~ /(authorization|password|passwd|api[_-]?key|access[_-]?token|secret|private[_ -]?key|credential)/) print "[REDACTED sensitive log line]"; else print }' "$1"
        }
        sanitize_log \(ShellEscaping.singleQuote(stdoutRaw)) >\(ShellEscaping.singleQuote(stdoutLog))
        sanitize_log \(ShellEscaping.singleQuote(stderrRaw)) >\(ShellEscaping.singleQuote(stderrLog))
        { printf '%s\\n' '--- stdout ---'; cat \(ShellEscaping.singleQuote(stdoutLog)); printf '%s\\n' '--- stderr ---'; cat \(ShellEscaping.singleQuote(stderrLog)); } >\(ShellEscaping.singleQuote(fullLog))
        rm -f \(ShellEscaping.singleQuote(stdoutRaw)) \(ShellEscaping.singleQuote(stderrRaw))
        summarize() { lines="$(wc -l <"$1" | tr -d ' ')"; if test "$lines" -le 120; then cat "$1"; else sed -n '1,60p' "$1"; printf '%s\\n' '...[summary truncated]...'; tail -60 "$1"; fi; }
        printf '__MINIS_BUILD_EXIT__=%s\\n' "$command_rc"
        printf '__MINIS_BUILD_DURATION__=%s\\n' "$((end-start))"
        printf '__MINIS_BUILD_STDOUT__='; summarize \(ShellEscaping.singleQuote(stdoutLog)) | base64 | tr -d '\\n'; printf '\\n'
        printf '__MINIS_BUILD_STDERR__='; summarize \(ShellEscaping.singleQuote(stderrLog)) | base64 | tr -d '\\n'; printf '\\n'
        printf '__MINIS_BUILD_DIAGNOSTICS__='; grep -E '(^|:)([0-9]+:)?[0-9]*:?[[:space:]]*(fatal error|error|warning|note):|(^|[[:space:]])(fatal error|error|warning):|make(\\[[0-9]+\\])?: \\*\\*\\*' \(ShellEscaping.singleQuote(fullLog)) 2>/dev/null | head -500 | base64 | tr -d '\\n'; printf '\\n'
        printf '__MINIS_BUILD_LOG__=%s\\n' \(ShellEscaping.singleQuote(fullLog))
        grep '^__MINIS_REMOTE__' \(ShellEscaping.singleQuote(stdoutLog)) 2>/dev/null | tail -1 || true
        grep '^__MINIS_JOB__' \(ShellEscaping.singleQuote(stdoutLog)) 2>/dev/null || true
        grep '^__MINIS_ARTIFACT__' \(ShellEscaping.singleQuote(stdoutLog)) 2>/dev/null || true
        exit 0
        """
        let started = Date()
        do {
            let result = try await executor(script, TimeInterval(max(30, timeout)))
            guard result.exitCode == 0 else {
                return .completed(.init(command: displayCommand, exitCode: result.exitCode, durationSeconds: Date().timeIntervalSince(started), stdoutSummary: "", stderrSummary: "Build wrapper failed before command completion.", fullLogPath: fullLog, diagnosticExcerpt: "", remoteMetadata: [:], remoteJobs: [], remoteArtifacts: []))
            }
            return .completed(parse(result.output, command: displayCommand, fallbackDuration: Date().timeIntervalSince(started), fallbackLog: fullLog))
        } catch {
            return .completed(.init(command: displayCommand, exitCode: -1, durationSeconds: Date().timeIntervalSince(started), stdoutSummary: "", stderrSummary: "Execution error: \(error.localizedDescription)", fullLogPath: fullLog, diagnosticExcerpt: "", remoteMetadata: [:], remoteJobs: [], remoteArtifacts: []))
        }
    }

    private static func parse(_ output: String, command: String, fallbackDuration: Double, fallbackLog: String) -> BuildCommandExecution {
        var exitCode = -1
        var duration = fallbackDuration
        var stdout = ""
        var stderr = ""
        var diagnostics = ""
        var log = fallbackLog
        var remote: [String: String] = [:]
        var remoteJobs: [RemoteJobMetadata] = []
        var remoteArtifacts: [RemoteArtifactMetadata] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("__MINIS_BUILD_EXIT__=") { exitCode = Int(line.dropFirst(21)) ?? -1 }
            else if line.hasPrefix("__MINIS_BUILD_DURATION__=") { duration = Double(line.dropFirst(25)) ?? fallbackDuration }
            else if line.hasPrefix("__MINIS_BUILD_STDOUT__=") { stdout = decode(String(line.dropFirst(23))) }
            else if line.hasPrefix("__MINIS_BUILD_STDERR__=") { stderr = decode(String(line.dropFirst(23))) }
            else if line.hasPrefix("__MINIS_BUILD_DIAGNOSTICS__=") { diagnostics = decode(String(line.dropFirst(28))) }
            else if line.hasPrefix("__MINIS_BUILD_LOG__=") { log = String(line.dropFirst(20)) }
            else if line.hasPrefix("__MINIS_REMOTE__") {
                for pair in line.dropFirst(16).split(separator: " ") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if parts.count == 2 { remote[parts[0]] = parts[1] }
                }
            } else if line.hasPrefix("__MINIS_JOB__"), let job = parseRemoteJob(line, repository: remote["repository"]) {
                remoteJobs.append(job)
            } else if line.hasPrefix("__MINIS_ARTIFACT__"), let artifact = parseRemoteArtifact(line) {
                remoteArtifacts.append(artifact)
            }
        }
        let (safeOut, _) = EnvVarRedactor.redactIfEnabled(stdout)
        let (safeErr, _) = EnvVarRedactor.redactIfEnabled(stderr)
        let (safeDiagnostics, _) = EnvVarRedactor.redactIfEnabled(diagnostics)
        return BuildCommandExecution(command: command, exitCode: exitCode, durationSeconds: duration, stdoutSummary: safeOut, stderrSummary: safeErr, fullLogPath: log, diagnosticExcerpt: safeDiagnostics, remoteMetadata: remote, remoteJobs: remoteJobs, remoteArtifacts: remoteArtifacts)
    }

    private static func parseRemoteJob(_ line: String, repository: String?) -> RemoteJobMetadata? {
        let value = String(line.dropFirst("__MINIS_JOB__".count))
        guard value.hasPrefix("id="),
              let nameRange = value.range(of: " name="),
              let statusRange = value.range(of: " status=", range: nameRange.upperBound..<value.endIndex),
              let conclusionRange = value.range(of: " conclusion=", range: statusRange.upperBound..<value.endIndex),
              let htmlRange = value.range(of: " html_url=", range: conclusionRange.upperBound..<value.endIndex),
              let apiRange = value.range(of: " api_url=", range: htmlRange.upperBound..<value.endIndex),
              let id = Int64(value[value.index(value.startIndex, offsetBy: 3)..<nameRange.lowerBound]) else { return nil }
        let conclusion = String(value[conclusionRange.upperBound..<htmlRange.lowerBound])
        let repositoryFlag = repository.map { " --repo " + ShellEscaping.singleQuote($0) } ?? ""
        return RemoteJobMetadata(
            jobID: id,
            name: String(value[nameRange.upperBound..<statusRange.lowerBound]),
            status: String(value[statusRange.upperBound..<conclusionRange.lowerBound]),
            conclusion: conclusion.isEmpty ? nil : conclusion,
            htmlURL: String(value[htmlRange.upperBound..<apiRange.lowerBound]),
            apiURL: String(value[apiRange.upperBound...]),
            logCommand: "gh run view --job \(id) --log\(repositoryFlag)"
        )
    }

    private static func parseRemoteArtifact(_ line: String) -> RemoteArtifactMetadata? {
        let value = String(line.dropFirst("__MINIS_ARTIFACT__".count))
        guard value.hasPrefix("id="),
              let nameRange = value.range(of: " name="),
              let sizeRange = value.range(of: " size=", range: nameRange.upperBound..<value.endIndex),
              let expiredRange = value.range(of: " expired=", range: sizeRange.upperBound..<value.endIndex),
              let urlRange = value.range(of: " url=", range: expiredRange.upperBound..<value.endIndex),
              let id = Int64(value[value.index(value.startIndex, offsetBy: 3)..<nameRange.lowerBound]),
              let size = Int64(value[sizeRange.upperBound..<expiredRange.lowerBound]) else { return nil }
        return RemoteArtifactMetadata(
            artifactID: id,
            name: String(value[nameRange.upperBound..<sizeRange.lowerBound]),
            sizeBytes: size,
            expired: value[expiredRange.upperBound..<urlRange.lowerBound] == "true",
            archiveDownloadURL: String(value[urlRange.upperBound...])
        )
    }

    private static func decode(_ value: String) -> String {
        guard let data = Data(base64Encoded: value), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

enum BuildCommandPolicy {
    static func applying(configuration: String, to command: String) -> String {
        let lower = configuration.lowercased()
        var value = command
        value = value.replacingOccurrences(of: "-configuration Debug", with: "-configuration \(ShellEscaping.singleQuote(configuration))")
        value = value.replacingOccurrences(of: "-configuration Release", with: "-configuration \(ShellEscaping.singleQuote(configuration))")
        value = value.replacingOccurrences(of: "swift build -c debug", with: "swift build -c \(ShellEscaping.singleQuote(lower))")
        value = value.replacingOccurrences(of: "swift build -c release", with: "swift build -c \(ShellEscaping.singleQuote(lower))")
        if lower == "release" { value = value.replacingOccurrences(of: "assembleDebug", with: "assembleRelease") }
        return value
    }
}

enum CredentialLogPolicy {
    static func isSensitiveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["token", "secret", "password", "passwd", "api_key", "apikey", "private_key", "credential"].contains { lower.contains($0) }
    }

    static func redact(_ command: String) -> String {
        var value = command
        let patterns = [
            #"(?i)(token|secret|password|passwd|api[_-]?key|authorization|credential)\s*=\s*[^\s]+"#,
            #"(?i)(--token|--password|--secret|--api-key)\s+[^\s]+"#,
            #"https?://[^/@\s]+@"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "[REDACTED]")
        }
        return value
    }
}
