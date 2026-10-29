import Foundation

// Typecheck only. This must match the dictionary used by the Minis settings UI.
func checkBridgeImport() -> [String: String] {
    let status: [String: String] = OMToolchain.capabilityStatus()
    let _: String? = status["compiler_linked"]
    let _: String? = status["resource_headers"]
    let _: String? = status["host_architecture"]
    return status
}
