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
        case .node: return "npm"
        default: return nil
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
