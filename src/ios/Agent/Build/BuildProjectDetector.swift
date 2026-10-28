import Foundation

@MainActor
enum BuildProjectDetector {
    static func inspect(path: String, executor: BuildShellExecutor) async throws -> BuildProjectInspection {
        let quoted = ShellEscaping.singleQuote(path)
        let command = """
        set +x
        cd \(quoted) 2>/dev/null || exit 72
        b64() { printf '%s' "$1" | base64 | tr -d '\\n'; }
        printf 'ROOT='; b64 "$(pwd -P)"; printf '\\n'
        printf 'BRANCH='; b64 "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"; printf '\\n'
        printf 'COMMIT='; b64 "$(git rev-parse HEAD 2>/dev/null || true)"; printf '\\n'
        if test -n "$(git status --porcelain 2>/dev/null | head -1)"; then printf 'DIRTY='; b64 1; printf '\\n'; else printf 'DIRTY='; b64 0; printf '\\n'; fi
        if test -f Makefile && grep -Eq 'THEOS|common\\.mk|tweak\\.mk|package\\.mk' Makefile 2>/dev/null; then printf 'THEOS='; b64 1; printf '\\n'; else printf 'THEOS='; b64 0; printf '\\n'; fi
        remote="$(git remote get-url origin 2>/dev/null || true)"
        remote="$(printf '%s' "$remote" | sed -E 's#(https?://)[^/@]+@#\\1[REDACTED]@#')"
        printf 'REMOTE='; b64 "$remote"; printf '\\n'
        find . -maxdepth 4 \\( -type f \\( -name Package.swift -o -name Makefile -o -name Podfile -o -name project.yml -o -name Cargo.toml -o -name CMakeLists.txt -o -name package.json -o -name gradlew \\) -o -type d -name '*.xcodeproj' \\) \
          2>/dev/null | LC_ALL=C sort | while IFS= read -r item; do printf 'MANIFEST='; b64 "$item"; printf '\\n'; done
        find .github/workflows -maxdepth 1 -type f \\( -name '*.yml' -o -name '*.yaml' \\) 2>/dev/null | LC_ALL=C sort | while IFS= read -r item; do printf 'WORKFLOW='; b64 "$item"; printf '\\n'; done
        find . -maxdepth 7 -type f -path '*/xcshareddata/xcschemes/*.xcscheme' 2>/dev/null | LC_ALL=C sort | head -1 | while IFS= read -r item; do printf 'SCHEME='; b64 "$(basename "$item" .xcscheme)"; printf '\\n'; done
        """
        let result = try await executor(command, 30)
        guard result.exitCode == 0 else {
            throw BuildToolError.projectInspectionFailed(path: path, exitCode: result.exitCode)
        }

        var root = path
        var branch: String?
        var commit: String?
        var remote: String?
        var manifests: [String] = []
        var workflows: [String] = []
        var scheme: String?
        var isTheos = false
        var gitIsDirty = false
        for line in result.output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equal])
            let encoded = String(line[line.index(after: equal)...])
            guard let value = decodeBase64(encoded) else { continue }
            switch key {
            case "ROOT": root = value
            case "BRANCH": branch = value.nilIfEmpty
            case "COMMIT": commit = value.nilIfEmpty
            case "REMOTE": remote = value.nilIfEmpty
            case "MANIFEST": manifests.append(value)
            case "WORKFLOW": workflows.append(value)
            case "SCHEME": scheme = value.nilIfEmpty
            case "THEOS": isTheos = value == "1"
            case "DIRTY": gitIsDirty = value == "1"
            default: break
            }
        }

        let kind = classify(manifests: manifests, isTheos: isTheos)
        let stack = languageStack(for: manifests)
        let suggestions = suggestedCommands(
            root: root,
            kind: kind,
            manifests: manifests,
            workflows: workflows,
            scheme: scheme
        )
        var providers: [BuildProviderID] = []
        for suggestion in suggestions where !providers.contains(suggestion.provider) {
            providers.append(suggestion.provider)
        }
        if providers.isEmpty { providers = [.localISH, .macSSH, .remoteGitHubActions] }

        return BuildProjectInspection(
            canonicalPath: root,
            kind: kind,
            manifests: manifests,
            languageStack: stack,
            gitBranch: branch,
            gitCommit: commit,
            gitIsDirty: gitIsDirty,
            gitRemote: remote,
            suggestedProviders: providers,
            suggestedCommands: suggestions
        )
    }

    private static func decodeBase64(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func classify(manifests: [String], isTheos: Bool = false) -> ProjectBuildKind {
        let lower = manifests.map { $0.lowercased() }
        let hasXcode = lower.contains { $0.hasSuffix(".xcodeproj") }
        let hasSwift = lower.contains { $0.hasSuffix("package.swift") }
        let hasGradle = lower.contains { $0.hasSuffix("/gradlew") || $0 == "./gradlew" }
        let hasCargo = lower.contains { $0.hasSuffix("cargo.toml") }
        let hasCMake = lower.contains { $0.hasSuffix("cmakelists.txt") }
        let hasNode = lower.contains { $0.hasSuffix("package.json") }
        let makefiles = manifests.filter { $0 == "./Makefile" }
        let hasTheos = !makefiles.isEmpty && isTheos
        let flags = [hasXcode, hasSwift, hasGradle, hasCargo, hasCMake, hasNode, !makefiles.isEmpty].filter { $0 }.count
        if flags > 1 { return .mixed }
        if hasXcode { return .xcode }
        if hasSwift { return .swiftPackage }
        if hasTheos { return .theos }
        if hasGradle { return .gradle }
        if hasCargo { return .cargo }
        if hasCMake { return .cmake }
        if !makefiles.isEmpty { return .make }
        if hasNode { return .node }
        return .unknown
    }

    private static func languageStack(for manifests: [String]) -> [String] {
        var stack: [String] = []
        func add(_ value: String) { if !stack.contains(value) { stack.append(value) } }
        for path in manifests {
            let lower = path.lowercased()
            if lower.hasSuffix(".xcodeproj") || lower.hasSuffix("package.swift") { add("Swift/Objective-C") }
            if lower.hasSuffix("/gradlew") || lower == "./gradlew" { add("Kotlin/Java") }
            if lower.hasSuffix("cargo.toml") { add("Rust") }
            if lower.hasSuffix("cmakelists.txt") || lower.hasSuffix("makefile") { add("C/C++/Objective-C") }
            if lower.hasSuffix("package.json") { add("JavaScript/TypeScript") }
        }
        return stack
    }

    private static func suggestedCommands(
        root: String,
        kind: ProjectBuildKind,
        manifests: [String],
        workflows: [String],
        scheme: String?
    ) -> [SuggestedBuildCommand] {
        var result: [SuggestedBuildCommand] = []
        let xcode = manifests.first { $0.hasSuffix(".xcodeproj") }
        if let xcode {
            let inferredScheme = scheme ?? URL(fileURLWithPath: xcode).deletingPathExtension().lastPathComponent
            result.append(SuggestedBuildCommand(
                provider: .macSSH,
                purpose: "build",
                command: "xcodebuild -project \(ShellEscaping.singleQuote(String(xcode.dropFirst(2)))) -scheme \(ShellEscaping.singleQuote(inferredScheme)) -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build"
            ))
        }
        if let workflow = workflows.first {
            result.append(SuggestedBuildCommand(
                provider: .remoteGitHubActions,
                purpose: "build",
                command: String(workflow.dropFirst(2))
            ))
        }
        if manifests.contains("./Makefile") {
            let provider: BuildProviderID = kind == .theos ? .theos : .localISH
            result.append(SuggestedBuildCommand(provider: provider, purpose: "build", command: kind == .theos ? "make package" : "make"))
        }
        if let gradlew = manifests.first(where: { $0.hasSuffix("/gradlew") || $0 == "./gradlew" }) {
            let dir = URL(fileURLWithPath: String(gradlew.dropFirst(2))).deletingLastPathComponent().path
            let prefix = dir == "." || dir.isEmpty ? "./gradlew" : "cd \(ShellEscaping.singleQuote(dir)) && ./gradlew"
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "build", command: prefix + " assembleDebug"))
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "test", command: prefix + " test"))
        }
        if manifests.contains("./Package.swift") || manifests.contains(where: { $0.hasSuffix("/Package.swift") }) {
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "build", command: "swift build -c debug"))
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "test", command: "swift test"))
        }
        if manifests.contains(where: { $0.hasSuffix("Cargo.toml") }) {
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "build", command: "cargo build"))
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "test", command: "cargo test"))
        }
        if manifests.contains(where: { $0.hasSuffix("CMakeLists.txt") }) {
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "build", command: "cmake -S . -B build && cmake --build build"))
        }
        if manifests.contains(where: { $0.hasSuffix("package.json") }) {
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "build", command: "npm run build"))
            result.append(SuggestedBuildCommand(provider: .localISH, purpose: "test", command: "npm test"))
        }
        return result
    }
}

enum BuildToolError: LocalizedError {
    case invalidArguments(String)
    case projectInspectionFailed(path: String, exitCode: Int)
    case providerUnavailable(BuildProviderAvailability)
    case noSuggestedCommand(BuildProviderID)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        case .projectInspectionFailed(let path, let code): return "Could not inspect project at \(path) (exit \(code))."
        case .providerUnavailable(let availability): return "\(availability.provider.rawValue) unavailable: \(availability.reason)"
        case .noSuggestedCommand(let provider): return "No safe build command could be inferred for \(provider.rawValue); pass command explicitly."
        case .persistence(let message): return "Build history persistence failed: \(message)"
        }
    }
}

enum ShellEscaping {
    static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
