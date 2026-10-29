import Foundation

/// Read-only readiness surface for the future in-process Clang/ld64 provider.
///
/// This provider deliberately has no shell command and never falls back to iSH.
/// It becomes executable only after the host is built with both compiler gates:
/// OM_TOOLCHAIN_ENABLED=1 and OM_TOOLCHAIN_VERIFIED=1. The latter is a build
/// policy gate, not a claim that merely bundling headers or archives is safe.
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
