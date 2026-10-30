// Typecheck-only seam for unrelated app dependencies. The permission/client,
// native sheet, Settings view, navigation adapters and menus are REAL sources.
// This file is not a build provider and is never linked into the production App.
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AIChatViewModel: ObservableObject {
    static var activeSessionId: String?
    var sessionId: String?
    var remoteDeviceId: String?
}

struct FileToolResult { let output: String; let success: Bool }
enum EnvVarRedactor {
    static func redactIfEnabled(_ text: String) -> (String, Bool) { (text, false) }
}
struct AgentToolParam {
    enum ParamType { case string, integer }
    let type: ParamType
    let description: String
}
struct AgentToolDefinition {
    let name: String
    let description: String
    let parameters: [String: AgentToolParam]
    let required: [String]
    let propertyOrdering: [String]
}
func AppLocalized(_ value: String) -> String { value }
enum ChatColors { static let primaryText = Color(UIColor.label) }
