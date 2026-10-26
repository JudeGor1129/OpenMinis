// Compile-time interface stubs only. The actual coach files are compiled here;
// full app CI separately checks integration against the real implementations.
import Foundation
import Combine
import UIKit

struct CoachModality: OptionSet, Sendable {
    let rawValue: Int
    static let imageInput = CoachModality(rawValue: 1)
}
struct CoachCapabilities: Sendable { var supportedModalities: CoachModality = [.imageInput] }
struct LLMModel: Sendable {
    var id = "test"
    var capabilities = CoachCapabilities()
}
struct ModelEntry: Sendable { var model = LLMModel(); var providerInstanceId = "test" }
struct CoachInstance { var isEnabled = true }
@MainActor final class ProviderConfigStore {
    static let shared = ProviderConfigStore()
    func instance(for id: String) -> CoachInstance? { CoachInstance() }
}
@MainActor enum VisionGroupResolver {
    static func displayName(for entry: ModelEntry) -> String { "test" }
}
@MainActor final class SessionLockStore {
    static let shared = SessionLockStore()
    func isVisuallyLocked(_ id: String) -> Bool { false }
}
struct LLMUsage: Sendable {
    var inputTokens = 0; var outputTokens = 0
    var cacheReadInputTokens: Int?; var cacheCreationInputTokens: Int?
}
enum ThinkingLevel { case off }
enum AgentStopReason: Sendable { case endTurn, maxTokens }
enum AgentStreamEvent: Sendable { case textDelta(String), usage(LLMUsage), done(stopReason: AgentStopReason) }
enum AgentContentPart: Sendable { case text(String), imageData(data: Data, mimeType: String, linuxPath: String?) }
struct AgentMessage: Sendable {
    enum Role: Sendable { case user, assistant }
    let role: Role
    let parts: [AgentContentPart]
}
protocol AgentProvider {
    var model: LLMModel { get }
    func streamAgentMessage(messages: [AgentMessage], systemPrompt: String?, tools: [Int], maxTokens: Int, thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error>
}
struct CoachProvider: AgentProvider {
    var model = LLMModel()
    func streamAgentMessage(messages: [AgentMessage], systemPrompt: String?, tools: [Int], maxTokens: Int, thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> { .init { $0.finish() } }
}
enum ChatRole { case user, assistant }
enum CoachBlockKind { case text, other }
final class CoachBlock { var kind = CoachBlockKind.text; var content = "" }
final class ChatMessage { var role = ChatRole.user; var content = ""; var blocks: [CoachBlock] = [] }
@MainActor final class AIChatViewModel: ObservableObject {
    @Published var isProcessing = false
    var remoteDeviceId: String?
    var sessionId: String?; var draftId: String?; var vmInstanceId = "test"
    var messages: [ChatMessage] = []
    var activeModelHasNativeVision = true
    static var activeSessionId: String?
    func resolveCurrentEntry() -> ModelEntry? { ModelEntry() }
    static func makeAgentProvider(for entry: ModelEntry, sessionId: String?) async -> any AgentProvider { CoachProvider() }
    static func downsampledCameraJPEG(_ image: UIImage, maxLongEdge: CGFloat, quality: CGFloat) -> Data? { image.jpegData(compressionQuality: quality) }
}
@MainActor final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    enum Intent { case homeworkCoach, homeworkHint }
    var isCapturing = false
    func beginWhenReady(_ intent: Intent, completion: @escaping @MainActor @Sendable (Bool) -> Void) { completion(true) }
    func end(_ intent: Intent) {}
}
