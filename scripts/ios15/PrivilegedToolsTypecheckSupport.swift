import Foundation
// Only the switch interface is stubbed. The Objective-C bridge and the actual
// settings view compile against Apple's SDK in the quick-check job.
enum AgentToolSwitch: String {
    case rootHelper = "agent.tools.rootHelper.enabled"
    case fridaProcesses = "agent.tools.fridaProcesses.enabled"
    var key: String { rawValue }
}
