@preconcurrency import Speech
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Streams an actual spoken question to Apple's speech recognizer. Offline is
/// preferred and cloud audio is never used without explicit parental opt-in.
/// No audio files/logs are written. Public calls are safe from the camera queue.
final class HomeworkQuestionRecognizer: @unchecked Sendable {
    private struct AudioPacket: @unchecked Sendable {
        let buffer: CMSampleBuffer
        let duration: Double
    }
    private let queue = DispatchQueue(label: "com.openminis.homework.question")
    private let lock = NSLock()
    private var stopped = false
    private var pendingAudio = 0
    private var didReportBacklog = false
    private let allowNetwork: Bool
    private let onPartial: @Sendable (String) -> Void
    private let onQuestion: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    // Queue-owned state.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var partial = ""
    private var active = false
    private var preroll: [AudioPacket] = []
    private var prerollDuration = 0.0
    private var finishWork: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var endAudioWork: DispatchWorkItem?
    private var cloud = false
    private var finalized = false
    private var inputEnded = false

    init(allowNetwork: Bool, onPartial: @escaping @Sendable (String) -> Void,
         onQuestion: @escaping @Sendable (String) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) {
        self.allowNetwork = allowNetwork
        self.onPartial = onPartial
        self.onQuestion = onQuestion
        self.onFailure = onFailure
    }
    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }; return stopped
    }
    func start(completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard !isStopped else { completion("语音识别启动已取消。"); return }
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                completion("请允许语音识别权限后再开启语音老师。"); return
            }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
                completion("系统不支持中文语音识别。"); return
            }
            guard recognizer.supportsOnDeviceRecognition || allowNetwork else {
                completion("本设备暂不支持中文离线识别。下载系统语音资源，或由家长开启联网语音识别。"); return
            }
            guard recognizer.isAvailable else { completion("系统语音识别暂不可用，请稍后重试。"); return }
            self.recognizer = recognizer
            cloud = !recognizer.supportsOnDeviceRecognition
            completion(nil)
        }
    }
    func append(_ buffer: CMSampleBuffer) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard pendingAudio < 8 else {
            let report = !didReportBacklog
            didReportBacklog = true
            lock.unlock()
            if report { onFailure("语音处理积压，已停止，请重新提问。") }
            return
        }
        pendingAudio += 1
        lock.unlock()
        let seconds = CMSampleBufferGetDuration(buffer).seconds
        let packet = AudioPacket(buffer: buffer, duration: seconds.isFinite && seconds > 0 ? seconds : 0.03)
        queue.async { [self, packet] in
            defer { lock.lock(); pendingAudio -= 1; lock.unlock() }
            guard !isStopped, recognizer != nil else { return }
            if let request, !finalized, !inputEnded {
                request.appendAudioSampleBuffer(packet.buffer)
            } else {
                preroll.append(packet); prerollDuration += packet.duration
                while preroll.count > 32 || (prerollDuration > 0.55 && preroll.count > 1) {
                    prerollDuration -= preroll.removeFirst().duration
                }
            }
        }
    }
    func voiceActivity(_ value: Bool) {
        queue.async { [self] in
            guard !isStopped, recognizer != nil else { return }
            if value, inputEnded, !active { deliverQuestion(token: generation) }
            active = value
            if value {
                endAudioWork?.cancel(); endAudioWork = nil
                if request == nil { beginQuestion() }
            } else if request != nil {
                let token = generation
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == token, !self.active, !self.isStopped else { return }
                    self.inputEnded = true
                    self.request?.endAudio()
                    self.waitForFinal(token: token)
                }
                endAudioWork?.cancel(); endAudioWork = work
                // A short additional pause joins normal hesitation within a question.
                queue.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }
    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in
            generation &+= 1
            cancelQuestion()
            preroll.removeAll(); prerollDuration = 0
            recognizer = nil
        }
    }

    private func beginQuestion() {
        guard let recognizer else { return }
        generation &+= 1
        let token = generation
        partial = ""; finalized = false; inputEnded = false
        let input = SFSpeechAudioBufferRecognitionRequest()
        input.requiresOnDeviceRecognition = !cloud
        input.shouldReportPartialResults = true
        input.taskHint = .dictation
        input.contextualStrings = ["这道题", "为什么", "我不会", "解题思路", "没听懂"]
        request = input
        task = recognizer.recognitionTask(with: input) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            self?.queue.async { [weak self, text, final, failed] in
                guard let self, !self.isStopped, self.generation == token else { return }
                if let text, text != self.partial {
                    guard text.count <= 600 else {
                        self.abortQuestion("提问太长，请分成简短的问题再说。"); return
                    }
                    self.partial = text
                    self.onPartial(text)
                }
                if final { self.finalized = true }
                if failed || final {
                    if self.active {
                        // Do not present a prematurely finalized/truncated question.
                        self.abortQuestion("语音识别中断，已停止；请重新说完整的问题。")
                    } else { self.deliverQuestion(token: token) }
                }
            }
        }
        for packet in preroll { input.appendAudioSampleBuffer(packet.buffer) }
        preroll.removeAll(); prerollDuration = 0
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped, self.generation == token else { return }
            self.abortQuestion("单次提问超过四十秒，请分成短问题再说。")
        }
        deadline = work
        queue.asyncAfter(deadline: .now() + 40, execute: work)
    }
    private func waitForFinal(token: Int) {
        guard !isStopped, token == generation else { return }
        if finalized { deliverQuestion(token: token); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.active else { return }
            self.deliverQuestion(token: token)
        }
        finishWork?.cancel(); finishWork = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }
    private func deliverQuestion(token: Int) {
        guard !isStopped, token == generation, request != nil, !active else { return }
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        generation &+= 1
        cancelQuestion()
        // Quiet segments are not model prompts. Environmental noise can still
        // be misrecognized as speech; expose the recognized text to the parent.
        guard (2...600).contains(text.count) else {
            onPartial("")
            onFailure("没听清提问，请再说一遍。"); return
        }
        onQuestion(text)
    }
    private func abortQuestion(_ message: String) {
        generation &+= 1
        cancelQuestion()
        onFailure(message)
    }
    private func cancelQuestion() {
        endAudioWork?.cancel(); endAudioWork = nil
        finishWork?.cancel(); finishWork = nil
        deadline?.cancel(); deadline = nil
        if !inputEnded { request?.endAudio() }
        request = nil
        task?.cancel(); task = nil
        partial = ""; finalized = false; inputEnded = false
    }
}
