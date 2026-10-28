import Foundation

extension AIChatViewModel {
    func programmingBuildToolDefinitions() -> [AgentToolDefinition] {
        let title = AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user.")
        return [
            AgentToolDefinition(
                name: "build_project",
                description: "Inspect a project, select or validate a real BuildProvider, execute a build, parse diagnostics, optionally run tests, verify requested artifacts, and persist the build run. Providers: local_ish, theos, remote_github_actions, mac_ssh. Unconfigured providers return structured unavailable status. Build success requires exit code 0; tests passed requires test exit code 0; artifacts are available only after verification. Repair workflows are capped at 3-5 attempts.",
                parameters: [
                    "tool_title": title,
                    "project_path": AgentToolParam(type: .string, description: "Absolute iSH/Linux project directory."),
                    "provider": AgentToolParam(type: .string, description: "Optional provider. Omit to probe and select from project suggestions.", enumValues: BuildProviderID.allCases.map(\.rawValue)),
                    "configuration": AgentToolParam(type: .string, description: "Build configuration such as Debug or Release (default Debug)."),
                    "toolchain": AgentToolParam(type: .string, description: "Toolchain identity. Default auto probes the selected provider and includes it in the cache fingerprint."),
                    "command": AgentToolParam(type: .string, description: "Optional explicit build command. Never include credentials; configure them in the provider environment."),
                    "test_command": AgentToolParam(type: .string, description: "Optional test command. Tests are not claimed passed unless this command exits 0. For GitHub Actions this is a dedicated test workflow filename."),
                    "artifact_paths": AgentToolParam(type: .string, description: "Optional JSON array or newline-separated IPA/DEB/binary paths to verify after a successful build."),
                    "timeout": AgentToolParam(type: .integer, description: "Command timeout seconds (default 7200, max 14400)."),
                    "cache_policy": AgentToolParam(type: .string, description: "use (default), refresh, or ignore build cache metadata.", enumValues: ["use", "refresh", "ignore"]),
                    "attempt": AgentToolParam(type: .integer, description: "Current repair attempt, starting at 1."),
                    "max_attempts": AgentToolParam(type: .integer, description: "Repair budget, 3 by default and never above 5."),
                    "workflow": AgentToolParam(type: .string, description: "GitHub Actions workflow filename/path. No guessed run URL is used; the provider discovers the exact run id."),
                    "workflow_inputs": AgentToolParam(type: .string, description: "Optional JSON object of non-sensitive workflow_dispatch inputs. Credentials are refused; use GitHub secrets."),
                ],
                required: ["tool_title", "project_path"],
                propertyOrdering: ["tool_title", "project_path", "provider", "configuration", "toolchain", "command", "test_command", "artifact_paths", "timeout", "cache_policy", "attempt", "max_attempts", "workflow", "workflow_inputs"]
            ),
            AgentToolDefinition(
                name: "run_tests",
                description: "Run a real test command through the same BuildProvider seam. Only exit code 0 yields passed; unavailable providers and missing commands are reported structurally.",
                parameters: [
                    "tool_title": title,
                    "project_path": AgentToolParam(type: .string, description: "Absolute iSH/Linux project directory."),
                    "provider": AgentToolParam(type: .string, description: "Optional provider.", enumValues: BuildProviderID.allCases.map(\.rawValue)),
                    "test_command": AgentToolParam(type: .string, description: "Explicit test command, or dedicated workflow filename for remote_github_actions."),
                    "configuration": AgentToolParam(type: .string, description: "Configuration (default Debug)."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout seconds (default 3600)."),
                ],
                required: ["tool_title", "project_path"],
                propertyOrdering: ["tool_title", "project_path", "provider", "test_command", "configuration", "timeout"]
            ),
            AgentToolDefinition(
                name: "analyze_build_log",
                description: "Parse clang, Swift, xcodebuild and make diagnostics into file, line, column, severity, message and tool. Pass a full log path when possible; the first actionable error is returned separately so chain errors do not hide the root cause.",
                parameters: [
                    "tool_title": title,
                    "log_path": AgentToolParam(type: .string, description: "Path to a build log in iSH/Linux."),
                    "log_text": AgentToolParam(type: .string, description: "Inline log text when no path exists. Prefer log_path for long logs."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "log_path", "log_text"]
            ),
            AgentToolDefinition(
                name: "verify_artifact",
                description: "Verify a real IPA, DEB or binary: existence, non-zero size, SHA-256 and archive listing; inspect Mach-O architecture, encryption and signature when tools are available; parse DEB control and check rootless /var/jb payload paths. Capability gaps are reported as unavailable, never fabricated.",
                parameters: [
                    "tool_title": title,
                    "path": AgentToolParam(type: .string, description: "Artifact path in iSH/Linux."),
                    "kind": AgentToolParam(type: .string, description: "Optional override; otherwise inferred from extension.", enumValues: ArtifactKind.allCases.map(\.rawValue)),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "kind"]
            ),
        ]
    }

    func executeProgrammingBuildTool(name: String, argsJSON: String) async -> FileToolResult {
        guard let data = argsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return FileToolResult(output: "Error: arguments were not a JSON object.", success: false)
        }
        let executor: BuildShellExecutor = { [weak self] command, timeout in
            guard let self else { return BuildShellResult(output: "View model released.", exitCode: -1) }
            let result = try await self.executeCommand(command, timeout: timeout, lineCallback: { _ in })
            return BuildShellResult(output: result.output, exitCode: result.exitCode)
        }
        let encoder = JSONEncoder.programmingToolsEncoder()
        do {
            switch name {
            case "build_project":
                let request = try buildRequest(from: args, forTestsOnly: false)
                let result = try await ProgrammingBuildTools.shared.build(request: request, executor: executor)
                let output = try encodeToolOutput(result, encoder: encoder)
                let artifactRequirementMet = request.artifactPaths.isEmpty || result.artifacts.allSatisfy { $0.state == .available }
                let testRequirementMet = request.testCommand == nil || result.testsState == .passed
                return FileToolResult(output: output, success: result.buildState == .success && artifactRequirementMet && testRequirementMet && result.persistenceError == nil)
            case "run_tests":
                let request = try buildRequest(from: args, forTestsOnly: true)
                let result = try await ProgrammingBuildTools.shared.runTests(request: request, executor: executor)
                return FileToolResult(output: try encodeToolOutput(result, encoder: encoder), success: result.state == .passed)
            case "analyze_build_log":
                let analysis = try await ProgrammingBuildTools.shared.analyzeBuildLog(path: args["log_path"] as? String, text: args["log_text"] as? String, executor: executor)
                return FileToolResult(output: try encodeToolOutput(analysis, encoder: encoder), success: true)
            case "verify_artifact":
                guard let path = nonEmpty(args["path"] as? String) else { throw BuildToolError.invalidArguments("Missing path.") }
                let kind = (args["kind"] as? String).flatMap(ArtifactKind.init(rawValue:))
                let result = await ProgrammingBuildTools.shared.verifyArtifact(path: path, kind: kind, executor: executor)
                return FileToolResult(output: try encodeToolOutput(result, encoder: encoder), success: result.state == .available)
            default:
                return FileToolResult(output: "Error: unsupported programming build tool.", success: false)
            }
        } catch {
            return FileToolResult(output: "Error: \(error.localizedDescription)", success: false)
        }
    }

    private func buildRequest(from args: [String: Any], forTestsOnly: Bool) throws -> BuildRequest {
        guard let path = nonEmpty(args["project_path"] as? String) else {
            throw BuildToolError.invalidArguments("Missing project_path.")
        }
        let provider: BuildProviderID?
        if let raw = nonEmpty(args["provider"] as? String) {
            guard let parsed = BuildProviderID(rawValue: raw) else { throw BuildToolError.invalidArguments("Unknown provider: \(raw)") }
            provider = parsed
        } else { provider = nil }
        let cacheRaw = (args["cache_policy"] as? String) ?? "use"
        guard let cache = BuildCachePolicy(rawValue: cacheRaw) else { throw BuildToolError.invalidArguments("Invalid cache_policy.") }
        let workflowInputs = try parseWorkflowInputs(args["workflow_inputs"] as? String)
        let timeoutDefault = forTestsOnly ? 3_600 : 7_200
        return BuildRequest(
            projectPath: path,
            provider: provider,
            configuration: nonEmpty(args["configuration"] as? String) ?? "Debug",
            toolchain: nonEmpty(args["toolchain"] as? String) ?? "auto",
            command: nonEmpty(args["command"] as? String),
            testCommand: nonEmpty(args["test_command"] as? String),
            artifactPaths: parsePaths(args["artifact_paths"] as? String),
            timeoutSeconds: max(30, min(14_400, (args["timeout"] as? Int) ?? timeoutDefault)),
            cachePolicy: cache,
            attempt: max(1, (args["attempt"] as? Int) ?? 1),
            maxAttempts: max(1, min(5, (args["max_attempts"] as? Int) ?? 3)),
            workflow: nonEmpty(args["workflow"] as? String),
            workflowInputs: workflowInputs
        )
    }

    private func parsePaths(_ value: String?) -> [String] {
        guard let value = nonEmpty(value) else { return [] }
        if let data = value.data(using: .utf8), let paths = try? JSONDecoder().decode([String].self, from: data) {
            return paths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return value.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func parseWorkflowInputs(_ value: String?) throws -> [String: String] {
        guard let value = nonEmpty(value) else { return [:] }
        guard let data = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuildToolError.invalidArguments("workflow_inputs must be a JSON object.")
        }
        var result: [String: String] = [:]
        for (key, value) in object {
            guard key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
                  !CredentialLogPolicy.isSensitiveName(key) else {
                throw BuildToolError.invalidArguments("workflow_inputs must use non-sensitive alphanumeric keys.")
            }
            if let string = value as? String {
                result[key] = string
            } else if let bool = value as? Bool {
                result[key] = bool ? "true" : "false"
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            } else {
                throw BuildToolError.invalidArguments("workflow_inputs values must be strings, booleans, or numbers.")
            }
        }
        return result
    }

    private func encodeToolOutput<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> String {
        guard let output = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw BuildToolError.invalidArguments("Could not encode structured tool output.")
        }
        let (redacted, _) = EnvVarRedactor.redactIfEnabled(output)
        return redacted
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
