import Foundation
import CryptoKit

@MainActor
final class ProgrammingBuildTools {
    static let shared = ProgrammingBuildTools()

    private init() {}

    func build(request: BuildRequest, executor: @escaping BuildShellExecutor) async throws -> BuildToolResult {
        guard (1...5).contains(request.maxAttempts) else {
            throw BuildToolError.invalidArguments("max_attempts must be between 1 and 5.")
        }
        guard (1...request.maxAttempts).contains(request.attempt) else {
            throw BuildToolError.invalidArguments("attempt must be between 1 and max_attempts; the workflow stops after its configured repair budget.")
        }
        let inspection = try await BuildProjectDetector.inspect(path: request.projectPath, executor: executor)
        let baseContext = BuildProviderContext(inspection: inspection, request: request, executor: executor)
        var availability: [BuildProviderAvailability] = []
        for provider in BuildProviderRegistry.providers {
            availability.append(await provider.availability(for: baseContext))
        }
        let selectedID = selectProvider(requested: request.provider, inspection: inspection, availability: availability)
        let runID = UUID().uuidString.lowercased()
        guard let selectedID, let provider = BuildProviderRegistry.provider(selectedID) else {
            let fingerprint = fingerprint(inspection: inspection, configuration: request.configuration, toolchain: request.toolchain)
            let result = BuildToolResult(
                runID: runID,
                project: inspection,
                providerAvailability: availability,
                selectedProvider: nil,
                cacheFingerprint: fingerprint,
                cacheHit: false,
                sourceRunID: nil,
                buildState: .unavailable,
                testsState: .notRun,
                build: nil,
                tests: nil,
                diagnostics: BuildLogAnalyzer.analyze(""),
                artifacts: [],
                checkpoint: checkpoint(request: request, state: .unavailable, diagnostics: BuildLogAnalyzer.analyze(""), artifactResults: [], detail: "No configured provider can build this project."),
                persistenceError: nil,
                createdAt: Date()
            )
            return await persist(result, configuration: request.configuration, toolchain: request.toolchain)
        }

        let selectedAvailability = availability.first { $0.provider == selectedID }!
        guard selectedAvailability.isAvailable else {
            let fingerprint = fingerprint(inspection: inspection, configuration: request.configuration, toolchain: request.toolchain)
            let result = BuildToolResult(
                runID: runID,
                project: inspection,
                providerAvailability: availability,
                selectedProvider: selectedID,
                cacheFingerprint: fingerprint,
                cacheHit: false,
                sourceRunID: nil,
                buildState: .unavailable,
                testsState: .notRun,
                build: nil,
                tests: nil,
                diagnostics: BuildLogAnalyzer.analyze(""),
                artifacts: [],
                checkpoint: checkpoint(request: request, state: .unavailable, diagnostics: BuildLogAnalyzer.analyze(""), artifactResults: [], detail: selectedAvailability.reason),
                persistenceError: nil,
                createdAt: Date()
            )
            return await persist(result, configuration: request.configuration, toolchain: request.toolchain)
        }

        let toolchain = request.toolchain == "auto"
            ? await provider.resolvedToolchain(for: baseContext)
            : request.toolchain
        let cacheFingerprint = fingerprint(inspection: inspection, configuration: request.configuration, toolchain: toolchain)

        if request.cachePolicy == .use,
           inspection.gitCommit != nil,
           !inspection.gitIsDirty,
           let cached = try? await BuildRunStore.shared.cachedSuccess(fingerprint: cacheFingerprint, provider: selectedID) {
            var verified: [ArtifactVerificationResult] = []
            for path in request.artifactPaths {
                verified.append(await ArtifactVerifier.verify(path: path, requestedKind: nil, executor: executor))
            }
            if request.artifactPaths.isEmpty || verified.allSatisfy({ $0.state == .available }) {
                let cachedResult = BuildToolResult(
                    runID: runID,
                    project: inspection,
                    providerAvailability: availability,
                    selectedProvider: selectedID,
                    cacheFingerprint: cacheFingerprint,
                    cacheHit: true,
                    sourceRunID: cached.id,
                    buildState: .success,
                    testsState: cached.result.testsState,
                    build: cached.result.build,
                    tests: cached.result.tests,
                    diagnostics: cached.result.diagnostics,
                    artifacts: verified,
                    checkpoint: BuildWorkflowCheckpoint(attempt: request.attempt, maxAttempts: request.maxAttempts, stage: "cache-hit", firstError: nil, nextActions: verified.isEmpty ? ["Build success reused from a matching project+commit+configuration+toolchain fingerprint; no artifact was claimed available."] : ["Artifacts were re-verified against the cached successful build."], stopReason: "Matching successful build metadata found."),
                    persistenceError: nil,
                    createdAt: Date()
                )
                return await persist(cachedResult, configuration: request.configuration, toolchain: toolchain)
            }
        }

        let context = BuildProviderContext(inspection: inspection, request: request, executor: executor)
        let buildExecution: BuildCommandExecution?
        let buildState: BuildState
        switch await provider.build(context: context, runID: runID) {
        case .unavailable:
            buildExecution = nil
            buildState = .unavailable
        case .completed(let execution):
            buildExecution = execution
            // This is the sole build-success gate. Text such as "BUILD SUCCEEDED"
            // never overrides a non-zero/missing process status.
            buildState = execution.exitCode == 0 ? .success : .failed
        }

        let analysisText = [
            buildExecution?.diagnosticExcerpt,
            buildExecution?.stderrSummary,
            buildExecution?.stdoutSummary,
        ].compactMap { $0 }.joined(separator: "\n")
        let diagnostics = BuildLogAnalyzer.analyze(analysisText)

        var testExecution: BuildCommandExecution?
        var testsState: TestState = .notRun
        if buildState == .success, request.testCommand != nil {
            switch await provider.test(context: context, runID: runID) {
            case .unavailable:
                testsState = .unavailable
            case .completed(let execution):
                testExecution = execution
                // This is the sole test-pass gate.
                testsState = execution.exitCode == 0 ? .passed : .failed
            }
        }

        var artifacts: [ArtifactVerificationResult] = []
        if buildState == .success {
            for path in request.artifactPaths {
                artifacts.append(await ArtifactVerifier.verify(path: path, requestedKind: nil, executor: executor))
            }
        }

        let result = BuildToolResult(
            runID: runID,
            project: inspection,
            providerAvailability: availability,
            selectedProvider: selectedID,
            cacheFingerprint: cacheFingerprint,
            cacheHit: false,
            sourceRunID: nil,
            buildState: buildState,
            testsState: testsState,
            build: buildExecution,
            tests: testExecution,
            diagnostics: diagnostics,
            artifacts: artifacts,
            checkpoint: checkpoint(request: request, state: buildState, diagnostics: diagnostics, artifactResults: artifacts, detail: nil),
            persistenceError: nil,
            createdAt: Date()
        )
        return await persist(result, configuration: request.configuration, toolchain: toolchain)
    }

    func runTests(request: BuildRequest, executor: @escaping BuildShellExecutor) async throws -> RunTestsResult {
        let inspection = try await BuildProjectDetector.inspect(path: request.projectPath, executor: executor)
        let context = BuildProviderContext(inspection: inspection, request: request, executor: executor)
        let requestedID = request.provider ?? inspection.suggestedCommands.first(where: { $0.purpose == "test" })?.provider ?? .localISH
        guard let provider = BuildProviderRegistry.provider(requestedID) else {
            throw BuildToolError.invalidArguments("Unknown build provider.")
        }
        let availability = await provider.availability(for: context)
        let runID = UUID().uuidString.lowercased()
        guard availability.isAvailable else {
            return RunTestsResult(runID: runID, project: inspection, providerAvailability: availability, state: .unavailable, execution: nil, diagnostics: BuildLogAnalyzer.analyze(""), createdAt: Date())
        }
        switch await provider.test(context: context, runID: runID) {
        case .unavailable(let unavailable):
            return RunTestsResult(runID: runID, project: inspection, providerAvailability: unavailable, state: .unavailable, execution: nil, diagnostics: BuildLogAnalyzer.analyze(""), createdAt: Date())
        case .completed(let execution):
            let diagnostics = BuildLogAnalyzer.analyze([execution.diagnosticExcerpt, execution.stderrSummary, execution.stdoutSummary].joined(separator: "\n"))
            return RunTestsResult(runID: runID, project: inspection, providerAvailability: availability, state: execution.exitCode == 0 ? .passed : .failed, execution: execution, diagnostics: diagnostics, createdAt: Date())
        }
    }

    func analyzeBuildLog(path: String?, text: String?, executor: @escaping BuildShellExecutor) async throws -> BuildLogAnalysis {
        if let text, !text.isEmpty { return BuildLogAnalyzer.analyze(text) }
        guard let path, !path.isEmpty else { throw BuildToolError.invalidArguments("Pass log_path or log_text.") }
        let command = "test -f \(ShellEscaping.singleQuote(path)) || exit 66; grep -E '(^|:)([0-9]+:)?[0-9]*:?[[:space:]]*(fatal error|error|warning|note):|(^|[[:space:]])(fatal error|error|warning):|make(\\[[0-9]+\\])?: \\*\\*\\*|Command PhaseScriptExecution failed' \(ShellEscaping.singleQuote(path)) 2>/dev/null | head -1000"
        let result = try await executor(command, 30)
        guard result.exitCode == 0 else { throw BuildToolError.invalidArguments("Build log does not exist or is unreadable: \(path)") }
        return BuildLogAnalyzer.analyze(result.output)
    }

    func verifyArtifact(path: String, kind: ArtifactKind?, executor: @escaping BuildShellExecutor) async -> ArtifactVerificationResult {
        await ArtifactVerifier.verify(path: path, requestedKind: kind, executor: executor)
    }

    private func selectProvider(requested: BuildProviderID?, inspection: BuildProjectInspection, availability: [BuildProviderAvailability]) -> BuildProviderID? {
        if let requested { return requested }
        for provider in inspection.suggestedProviders {
            if availability.first(where: { $0.provider == provider })?.isAvailable == true { return provider }
        }
        return nil
    }

    private func fingerprint(inspection: BuildProjectInspection, configuration: String, toolchain: String) -> String {
        let material = [
            inspection.canonicalPath,
            inspection.gitCommit ?? "working-tree-no-commit",
            inspection.gitIsDirty ? "dirty" : "clean",
            configuration,
            toolchain,
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func checkpoint(request: BuildRequest, state: BuildState, diagnostics: BuildLogAnalysis, artifactResults: [ArtifactVerificationResult], detail: String?) -> BuildWorkflowCheckpoint {
        switch state {
        case .success:
            let invalid = artifactResults.filter { $0.state != .available }
            let actions = invalid.isEmpty
                ? ["Review the final diff and commit only after required tests and artifacts are verified."]
                : ["Do not report the artifact available; fix verification errors: " + invalid.flatMap(\.errors).joined(separator: "; ")]
            return .init(attempt: request.attempt, maxAttempts: request.maxAttempts, stage: invalid.isEmpty ? "verified" : "artifact-verification", firstError: nil, nextActions: actions, stopReason: invalid.isEmpty ? "Build command exited 0." : nil)
        case .failed:
            if request.attempt >= request.maxAttempts {
                return .init(attempt: request.attempt, maxAttempts: request.maxAttempts, stage: "stopped", firstError: diagnostics.firstError, nextActions: ["Escalate with the first compiler error and full log path; do not continue chain-error fixes."], stopReason: "Repair budget exhausted (maximum 3-5 rounds).")
            }
            return .init(attempt: request.attempt, maxAttempts: request.maxAttempts, stage: "repair", firstError: diagnostics.firstError, nextActions: ["Fix only the first actionable error.", "Run static/source guards.", "Call build_project again with attempt=\(request.attempt + 1)."], stopReason: nil)
        case .unavailable:
            return .init(attempt: request.attempt, maxAttempts: request.maxAttempts, stage: "provider-unavailable", firstError: nil, nextActions: [detail ?? "Configure one of the reported providers."], stopReason: "No command was executed; success was not fabricated.")
        case .queued:
            return .init(attempt: request.attempt, maxAttempts: request.maxAttempts, stage: "remote-queued", firstError: nil, nextActions: ["Wait for the exact remote run id and require its final exit status."], stopReason: nil)
        case .notRun:
            return .init(attempt: request.attempt, maxAttempts: request.maxAttempts, stage: "not-run", firstError: nil, nextActions: [], stopReason: detail)
        }
    }

    private func persist(_ result: BuildToolResult, configuration: String, toolchain: String) async -> BuildToolResult {
        let encoder = JSONEncoder.programmingToolsEncoder()
        let diagnostics = (try? encoder.encode(result.diagnostics)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let artifacts = (try? encoder.encode(result.artifacts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let resultJSON = (try? encoder.encode(result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let row = PersistedBuildRun(
            id: result.runID,
            projectPath: result.project.canonicalPath,
            gitCommit: result.project.gitCommit,
            configuration: configuration,
            toolchain: toolchain,
            provider: result.selectedProvider?.rawValue ?? "unselected",
            cacheFingerprint: result.cacheFingerprint,
            cacheHit: result.cacheHit,
            sourceRunID: result.sourceRunID,
            command: result.build?.command,
            exitCode: result.build?.exitCode,
            buildState: result.buildState,
            testsExitCode: result.tests?.exitCode,
            testsState: result.testsState,
            diagnosticsJSON: diagnostics,
            artifactPath: result.artifacts.first?.path,
            artifactJSON: artifacts,
            artifactState: result.artifacts.first?.state,
            logPath: result.build?.fullLogPath,
            duration: result.build?.durationSeconds ?? 0,
            resultJSON: resultJSON,
            createdAt: result.createdAt
        )
        do {
            try await BuildRunStore.shared.insert(row)
            return result
        } catch {
            return BuildToolResult(
                runID: result.runID,
                project: result.project,
                providerAvailability: result.providerAvailability,
                selectedProvider: result.selectedProvider,
                cacheFingerprint: result.cacheFingerprint,
                cacheHit: result.cacheHit,
                sourceRunID: result.sourceRunID,
                buildState: result.buildState,
                testsState: result.testsState,
                build: result.build,
                tests: result.tests,
                diagnostics: result.diagnostics,
                artifacts: result.artifacts,
                checkpoint: result.checkpoint,
                persistenceError: error.localizedDescription,
                createdAt: result.createdAt
            )
        }
    }
}
