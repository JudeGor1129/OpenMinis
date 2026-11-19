import Foundation
import AVFoundation
import CoreFoundation
import Darwin
import UIKit

// MARK: - Voice-output preference (persisted)

enum VoiceOutputPreferences {
    private static let key = "voice.output.readRepliesAloud"
    private static let speedKey = "voice.output.speedMultiplier"

    /// Whether agent replies should be read aloud via TTS.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The speed steps the floating speaker button cycles through.
    static let speedSteps: [Float] = [1.0, 1.25, 1.5, 2.0]

    /// Playback speed multiplier for read-replies TTS (applies to subsequently
    /// generated/queued utterances). Persisted so it survives across replies.
    static var speedMultiplier: Float {
        get {
            let v = UserDefaults.standard.object(forKey: speedKey) as? Float ?? 1.0
            return speedSteps.contains(v) ? v : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: speedKey) }
    }

    private static let mutedKey = "voice.output.muted"

    /// Whether read-replies is temporarily muted (persisted so it survives restart).
    static var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: mutedKey) }
        set { UserDefaults.standard.set(newValue, forKey: mutedKey) }
    }

    private static let offXKey = "voiceCapsule.anchorOffset.dx"
    private static let offYKey = "voiceCapsule.anchorOffset.dy"

    /// Last dragged offset of the floating capsule RELATIVE to its default
    /// bottom-trailing resting corner. Window-size independent: the capsule
    /// keeps its distance from the anchor corner across rotation / iPad Stage
    /// Manager window resizes. (The previous scheme persisted an ABSOLUTE
    /// window-coordinate center, which landed mid-content once the window
    /// shrank.) nil = never dragged → default resting corner.
    static var capsuleAnchorOffset: CGSize? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: offXKey) != nil, d.object(forKey: offYKey) != nil else { return nil }
            return CGSize(width: d.double(forKey: offXKey), height: d.double(forKey: offYKey))
        }
        set {
            let d = UserDefaults.standard
            if let o = newValue {
                d.set(Double(o.width), forKey: offXKey)
                d.set(Double(o.height), forKey: offYKey)
            } else {
                d.removeObject(forKey: offXKey)
                d.removeObject(forKey: offYKey)
            }
        }
    }
}

// MARK: - VoiceOutputPlayer
//
// Ordered, streaming TTS queue for reading replies aloud with a CONFIGURED cloud
// voice model (Groq/MiniMax/Doubao/…). Text units (sentences / titles / tool
// announcements) are enqueued in order; audio is generated ahead of time
// (pipelined, up to `maxPrefetch` concurrent synthesize requests) but PLAYED
// strictly in enqueue order, so playback stays gapless and correctly sequenced.
//
// The offline System provider is NOT handled here — the AIChatViewModel keeps its
// existing AVSpeechSynthesizer path for System (it already carries voice/rate/
// pitch/volume + background keep-alive). This player is the cloud-model path.

@MainActor
final class VoiceOutputPlayer: NSObject, ObservableObject {

    static let shared = VoiceOutputPlayer()

    private var activePetSpeechRequest: PetSpeechRequest?
    private var petSpeechTask: Task<Void, Never>?
    private var petSpeechWatchdog: Task<Void, Never>?
    private var lastPetSpeechPrune: TimeInterval = -.infinity

    private override init() {
        super.init()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let player = Unmanaged<VoiceOutputPlayer>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in player.drainPetSpeechInbox() }
            }, "com.judegor.minispet.speech.request" as CFString, nil, .deliverImmediately)
    }

    func startPetSpeechBridge() { drainPetSpeechInbox() }

    @Published private(set) var isPlaying = false
    /// True while a cloud TTS network synthesis is in flight with nothing yet
    /// playing — drives the "…" loading animation on the speaker control so the
    /// user knows audio is being generated (not stuck).
    @Published private(set) var isSynthesizing = false
    /// Display name of the model that LAST successfully synthesized — set when a
    /// fail-over picks a different group member, so the speech control's capsule
    /// can show the model that's actually producing audio. nil = use the resolved
    /// default label.
    @Published private(set) var activeModelLabel: String?
    /// Bumped each time a unit fully fails (all candidates exhausted) — the speech
    /// control observes it to flash the speaker icon red for a few seconds.
    @Published private(set) var synthFailureTick = 0

    /// One ordered fail-over candidate.
    struct Candidate {
        let key: String          // ModelEntry.id (stable identity for stickiness)
        let modelId: String?
        /// [T-ios-tts-voice-never-sent] The voice to synthesize with — the SAME
        /// `ModelEntry.model.id` as `modelId`, because model entries double as
        /// voices in this architecture (see the note in `VoiceProviderTemplate`:
        /// the Azure catalog is a list of voice names, not models).
        ///
        /// Carried as its own field so it can be handed to `VoiceOutputRequest`
        /// as `voice:`. It used to travel only as `model:`, which meant every
        /// vendor that reads `request.voice` FIRST — Azure (`?? default`),
        /// Xunfei, Gemini, and the base-class OpenAI-compatible body — saw nil
        /// and silently fell back to its default voice. Azure's default is
        /// `zh-CN-XiaoxiaoNeural`, a female voice: exactly the reported
        /// "every voice tests fine but playback is always the default woman".
        let voiceId: String?
        let label: String
        let provider: any VoiceOutputCapable
        /// The entry's model, so providers can route by its catalog voice role.
        /// [T-openrouter-voice-catalog]
        var resolvedModel: LLMModel? = nil
    }
    /// STICKY cursor: the ModelEntry.id we're currently synthesizing with. Persists
    /// across units (and the whole reply) until that model fails, then advances.
    private var stickyCandidateKey: String?

    /// Recompute `isSynthesizing`: a unit is generating (task running, no audio
    /// yet) AND nothing is currently playing (so it reads as "loading", not as a
    /// background prefetch behind active playback).
    private func refreshSynthesizingState() {
        let generating = queue.contains { $0.task != nil && $0.audio == nil && !$0.failed }
        let next = generating && player == nil
        if next != isSynthesizing { isSynthesizing = next }
    }

    private let logger = AppLogger(category: "VoiceOutput")
    private var player: AVAudioPlayer?

    /// One queued unit: its order index, source text, and (once generated) audio.
    /// `ownerSessionId` records which chat session (or manual read-aloud source)
    /// enqueued it, so `stopSession` can clear ONE session's units without
    /// touching other concurrent sessions' queued speech.
    private final class Unit {
        let seq: Int
        let text: String
        let ownerSessionId: String
        var audio: Data?          // nil until synthesize completes
        var failed = false        // synthesize errored → skip on playback
        var task: Task<Void, Never>?
        init(seq: Int, text: String, ownerSessionId: String) {
            self.seq = seq; self.text = text; self.ownerSessionId = ownerSessionId
        }
    }

    private var queue: [Unit] = []      // pending + generating, in order
    private var nextSeq = 0
    private var playingSeq = -1         // seq currently playing (-1 = idle)
    /// Owner session of the unit currently playing (nil = idle).
    private var playingSessionId: String?

    /// Owner id used by non-session read-aloud entry points (long-press menu,
    /// markdown preview) — never collides with a real session id.
    static let manualOwnerId = "__manual__"

    // MARK: - Dynamic TTS window measurement
    // Exponentially-smoothed estimates from completed synth+play cycles, used to
    // recommend how many characters the next batch should accumulate so audio
    // never under-runs (next batch's audio ≥ time to synthesize it) but batches
    // aren't so large they risk a synth timeout.
    /// Seconds of AUDIO produced per source character (e.g. ~0.18 s/char for CJK).
    private var secPerChar: Double = 0.18
    /// Seconds of SYNTHESIS time per source character (network + model).
    private var synthSecPerChar: Double = 0.05
    /// Fixed synthesis latency per request (s) — connection + model warmup.
    private var synthLatency: Double = 0.6
    /// Safety factor (<1) applied to the computed minimum so accumulation stays
    /// slightly ahead of consumption instead of exactly matching it.
    private static let windowSafety: Double = 0.8
    /// Hard ceiling on a single batch's character count (avoid synth timeouts).
    static let maxBatchChars = 220
    /// Floor so we never recommend a uselessly tiny batch.
    static let minBatchChars = 8
    /// Retry the SAME text this many times before falling back to splitting it.
    static let synthRetriesSameText = 2
    /// Backoff between retries (seconds), grows per attempt.
    static let synthRetryBackoff = 0.4
    /// Sub-chunk size when a too-long / rejected batch is split for a final retry.
    static let synthSplitChunkChars = 60
    /// Max concurrent synthesize requests running ahead of playback.
    private static let maxPrefetch = 2

    // MARK: - Dynamic window

    /// Update the smoothed per-char audio / synth estimates from one cycle.
    private func recordSynthMetrics(chars: Int, synthTime: Double, wav: Data) {
        guard chars > 0 else { return }
        let audioDur = Self.wavDuration(wav)
        guard audioDur > 0.05, synthTime > 0.01 else { return }
        let a = 0.3   // smoothing
        secPerChar      += (audioDur / Double(chars)  - secPerChar)      * a
        synthSecPerChar += (synthTime / Double(chars) - synthSecPerChar) * a
        // Latency ≈ synthTime minus the per-char portion (floored at 0).
        let perCharPart = synthSecPerChar * Double(chars)
        synthLatency    += (max(0, synthTime - perCharPart) - synthLatency) * a
    }

    /// How many seconds of generated-but-not-yet-played audio are buffered now
    /// (the front unit's remaining time + all ready units behind it).
    private var bufferedAudioSeconds: Double {
        var total = 0.0
        if let p = player { total += max(0, p.duration - p.currentTime) }
        for u in queue where u.audio != nil && !u.failed {
            total += Self.wavDuration(u.audio!)
        }
        return total
    }

    /// Recommended minimum characters for the NEXT batch so audio doesn't
    /// under-run. Base requirement (no buffer): enough chars that the batch's
    /// audio duration covers the time to synthesize it —
    ///   N·secPerChar ≥ synthLatency + N·synthSecPerChar
    ///   ⇒ N ≥ synthLatency / (secPerChar − synthSecPerChar)
    /// Then ×0.8 (don't over-accumulate). When there's ALREADY buffered audio
    /// (mid/late reply), we can afford to wait for a LONGER, more coherent batch —
    /// grow the minimum proportionally to the buffer, capped at maxBatchChars.
    var recommendedMinChars: Int {
        let denom = max(0.02, secPerChar - synthSecPerChar)
        let base = (synthLatency / denom) * Self.windowSafety
        // Buffer headroom in seconds → extra chars we can wait to coalesce.
        let headroomChars = (bufferedAudioSeconds / max(0.01, secPerChar)) * Self.windowSafety
        let n = Int((base + headroomChars).rounded())
        return max(Self.minBatchChars, min(Self.maxBatchChars, n))
    }

    /// Whether the queue currently has any audio playing/ready (used by the caller
    /// to apply the "speak the first batch ASAP" rule when idle).
    var hasPendingAudio: Bool {
        player != nil || queue.contains { $0.audio != nil && !$0.failed }
    }

    private static func wavDuration(_ wav: Data) -> Double {
        guard wav.count > 44 else { return 0 }
        let byteRate = wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self) }
        let rate = UInt32(littleEndian: byteRate)
        guard rate > 0 else { return 0 }
        return Double(wav.count - 44) / Double(rate)
    }

    // MARK: - Public API

    /// Enqueue a text unit to be read aloud via the configured cloud TTS model.
    /// No-op when read-aloud is off or the text is blank. Order is preserved.
    /// `sessionId` tags the unit's owner so `stopSession` can clear one
    /// session's speech without touching concurrent sessions'.
    func enqueue(_ text: String, sessionId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceOutputPreferences.isEnabled, !trimmed.isEmpty else { return }

        let unit = Unit(seq: nextSeq, text: trimmed, ownerSessionId: sessionId); nextSeq += 1
        queue.append(unit)
        VoiceLog.log(String(format: "TTS enqueue #%d owner=%@ chars=%d queue=%d buffered=%.2fs est[sec/ch=%.3f synth/ch=%.3f lat=%.2f minChars=%d] \"%@\"",
            unit.seq, String(sessionId.prefix(8)), trimmed.count, queue.count, bufferedAudioSeconds,
            secPerChar, synthSecPerChar, synthLatency, recommendedMinChars,
            String(trimmed.prefix(30))))
        pumpPrefetch()
        pumpPlayback()
    }

    // The host never starts a background mode on behalf of the pet.
    private var petSpeechMayRun: Bool {
        let state = UIApplication.shared.applicationState
        return state == .active || (state == .background && BackgroundKeepAliveManager.shared.enhancedBackgroundEffective)
    }

    private func drainPetSpeechInbox() {
        guard petSpeechMayRun else { petSpeechTask?.cancel(); return }
        let directory = PetSpeechMailbox.openDirectory()
        guard directory >= 0 else { petSpeechTask?.cancel(); return }
        let current = PetSpeechMailbox.readRequest(from: directory)
        if let activePetSpeechRequest {
            close(directory)
            if current != activePetSpeechRequest { petSpeechTask?.cancel() }
            return
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastPetSpeechPrune >= 60 {
            PetSpeechMailbox.prune(in: directory)
            lastPetSpeechPrune = uptime
        }
        guard let request = current, PetSpeechMailbox.claim(request.id, in: directory) else {
            close(directory)
            return
        }
        let age = Date().timeIntervalSince1970 - request.createdAt
        let deadline = uptime + max(0, PetSpeechMailbox.lifetime - max(0, age))
        activePetSpeechRequest = request
        petSpeechTask = Task { [weak self] in
            defer { close(directory) }
            guard let self else { return }
            await self.servePetSpeech(request, in: directory, deadline: deadline)
            self.petSpeechWatchdog?.cancel()
            self.petSpeechWatchdog = nil
            self.activePetSpeechRequest = nil
            self.petSpeechTask = nil
            // A newer lease may have arrived while cancellation was in flight.
            self.drainPetSpeechInbox()
        }
        petSpeechWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if !self.petSpeechIsCurrent(request, in: directory, deadline: deadline) {
                    self.petSpeechTask?.cancel()
                    return
                }
            }
        }
    }

    private func petSpeechIsCurrent(_ request: PetSpeechRequest, in directory: Int32, deadline: TimeInterval) -> Bool {
        !Task.isCancelled && petSpeechMayRun && activePetSpeechRequest == request &&
            ProcessInfo.processInfo.systemUptime < deadline && PetSpeechMailbox.readRequest(from: directory) == request
    }

    private func servePetSpeech(_ request: PetSpeechRequest, in directory: Int32, deadline: TimeInterval) async {
        guard petSpeechIsCurrent(request, in: directory, deadline: deadline) else { return }
        let text = VoiceTextSanitizer.sanitize(request.text)
        guard (2...PetSpeechMailbox.textLimit).contains(text.utf16.count) else {
            await finishPetSpeech(request, in: directory, deadline: deadline, failure: "invalid_text")
            return
        }
        let entries = VoiceProviderResolver.resolvedOutputCandidates()
        var triedCloudProvider = false
        for entry in entries {
            guard petSpeechIsCurrent(request, in: directory, deadline: deadline) else { return }
            guard !VoiceProviderResolver.isSystemEntry(entry.providerInstanceId),
                  let provider = VoiceProviderResolver.outputProvider(for: entry),
                  !(provider is SystemVoiceProvider) else { continue }
            triedCloudProvider = true
            let input = VoiceOutputRequest(input: text, model: entry.model.id, voice: entry.model.id,
                                          responseFormat: .mp3, resolvedModel: entry.model)
            do {
                let bytes = try await provider.synthesize(input)
                guard petSpeechIsCurrent(request, in: directory, deadline: deadline) else { return }
                guard let suffix = PetSpeechMailbox.audioSuffix(bytes) else { continue }
                await finishPetSpeech(request, in: directory, deadline: deadline, audio: (bytes, suffix))
                return
            } catch is CancellationError {
                return
            } catch {
                // The next configured cloud entry can try the same line within the lease.
            }
        }
        await finishPetSpeech(request, in: directory, deadline: deadline,
                              failure: triedCloudProvider ? "synthesis_failed" : "cloud_tts_unconfigured")
    }

    private func finishPetSpeech(_ request: PetSpeechRequest, in directory: Int32, deadline: TimeInterval,
                                 audio: (Data, String)? = nil, failure: String = "write_failed") async {
        guard petSpeechIsCurrent(request, in: directory, deadline: deadline) else { return }
        var result: [String: Any] = ["schema": 1, "request_id": request.id, "request_created_at": request.createdAt]
        var audioName: String?
        if let (bytes, suffix) = audio {
            let name = "audio-\(request.id).\(suffix)"
            // Keep the descriptor alive until the writer finishes. Only the
            // main actor publishes a receipt, after rechecking the live lease.
            let written = await Task.detached(priority: .utility) {
                PetSpeechMailbox.write(bytes, named: name, in: directory)
            }.value
            if written {
                audioName = name
                result["audio"] = name
                result["audio_bytes"] = bytes.count
            }
        }
        result["ok"] = audioName != nil
        if audioName == nil { result["error"] = failure }
        let created = Date().timeIntervalSince1970
        result["created_at"] = created
        let receipt = "response-\(request.id).json"
        guard created >= request.createdAt,
              let data = try? JSONSerialization.data(withJSONObject: result),
              petSpeechIsCurrent(request, in: directory, deadline: deadline),
              PetSpeechMailbox.write(data, named: receipt, in: directory),
              petSpeechIsCurrent(request, in: directory, deadline: deadline) else {
            if let audioName { unlinkat(directory, audioName, 0) }
            unlinkat(directory, receipt, 0)
            return
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("com.judegor.minispet.speech.response" as CFString), nil, nil, true)
    }

    /// Sanitize, split into speech-sized segments using the streaming segmenter,
    /// and enqueue each segment. Used by long-press "Read Aloud" / markdown
    /// preview / "Read Selected" — same splitting as live streaming TTS.
    /// Non-session callers pass `VoiceOutputPlayer.manualOwnerId`.
    func enqueueSegmented(_ rawText: String, sessionId: String) {
        let sanitized = VoiceTextSanitizer.sanitize(rawText)
        guard !sanitized.isEmpty else { return }
        let segments = AIChatViewModel.splitIntoSpeechSegments(sanitized)
        for s in segments { enqueue(s, sessionId: sessionId) }
    }

    /// Stop everything: cancel in-flight synth, clear the queue, stop playback.
    func stopAll() {
        for u in queue { u.task?.cancel() }
        queue.removeAll()
        player?.stop()
        player = nil
        playingSeq = -1
        playingSessionId = nil
        isPlaying = false
        isPaused = false
        isSynthesizing = false
        releaseSessionIfSafe()
    }

    /// Clear ONE session's queued/synthesizing units. If the currently-playing
    /// unit belongs to that session, stop it and continue with the next unit
    /// from other sessions. Units owned by other sessions are untouched — this
    /// is what lets multiple concurrent chats share the queue without a new
    /// reply in one chat wiping another chat's pending speech.
    func stopSession(_ sessionId: String) {
        let owned = queue.filter { $0.ownerSessionId == sessionId }
        guard !owned.isEmpty || playingSessionId == sessionId else { return }
        for u in owned { u.task?.cancel() }
        queue.removeAll { $0.ownerSessionId == sessionId }
        VoiceLog.log("TTS stopSession owner=\(String(sessionId.prefix(8))) cleared=\(owned.count) remaining=\(queue.count) playingWasOurs=\(playingSessionId == sessionId)")
        if playingSessionId == sessionId {
            player?.stop()
            player = nil
            playingSeq = -1
            playingSessionId = nil
            isPaused = false
            pumpPlayback()   // continue with other sessions' queued content
        }
        refreshSynthesizingState()
        if queue.isEmpty && player == nil {
            isPlaying = false
            releaseSessionIfSafe()
        }
    }

    /// Clear the sticky fail-over cursor + active-model label. Call when the user
    /// MANUALLY changes the voice output selection so the capsule reflects the new
    /// choice instead of a stale failed-over model.
    func resetActiveModel() {
        stickyCandidateKey = nil
        activeModelLabel = nil
    }

    @Published private(set) var isPaused = false

    /// Apply a new playback rate to the CURRENTLY-playing cloud audio immediately
    /// (real-time speed change). New units pick it up from VoiceOutputPreferences.
    func setRate(_ rate: Float) {
        player?.enableRate = true
        player?.rate = rate
    }

    /// Pause the currently-playing cloud audio (queue keeps filling in background).
    /// Sets `isPaused` even when there's no live `player` yet — an external
    /// recording can silence/stop our AVAudioPlayer BEFORE the pause signal
    /// arrives, and we still need `isPaused` latched so `pumpPlayback` won't
    /// start the next queued unit under the recorder, and so `resume()` knows to
    /// pick the queue back up. Playback stays gated on `!isPaused` in
    /// `pumpPlayback`.
    func pause() {
        if let p = player, p.isPlaying { p.pause() }
        isPaused = true
    }

    /// Resume paused cloud audio. Resumes the live player if one is paused, and
    /// ALWAYS kicks the pump so a queue that drained its player while paused
    /// (external recording stopped our AVAudioPlayer) starts its next unit.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        if let p = player { p.play() } else { pumpPlayback() }
    }

    /// The cloud TTS queue has drained — end the reply-TTS intent. The coordinator
    /// then re-applies the next-highest intent's profile (e.g. capture, keep-alive)
    /// or deactivates the session. No need to guard on capture here: the coordinator
    /// won't deactivate a session a higher-priority intent still owns.
    private func releaseSessionIfSafe() {
        AudioSessionCoordinator.shared.end(.replyTTS)
    }

    // MARK: - Pipeline

    /// Start synthesize for the earliest not-yet-generated units, up to maxPrefetch.
    private func pumpPrefetch() {
        let inFlight = queue.filter { $0.task != nil && $0.audio == nil && !$0.failed }.count
        var slots = Self.maxPrefetch - inFlight
        guard slots > 0 else { return }

        // Ordered fail-over candidates from the configured output group (override
        // first, then each usable group member). System voices are INCLUDED now —
        // SystemVoiceProvider.synthesize() returns a valid WAV, so a System candidate
        // plays through the same AVAudioPlayer path as any cloud model, which makes
        // mixed groups (e.g. [Doubao, System]) fail over cloud→System correctly.
        var candidates: [Candidate] =
            VoiceProviderResolver.resolvedOutputCandidates().compactMap { entry in
                guard let p = VoiceProviderResolver.outputProvider(for: entry) else { return nil }
                return Candidate(key: entry.id, modelId: entry.model.id,
                                 voiceId: entry.model.id,
                                 label: entry.model.displayName, provider: p,
                                 resolvedModel: entry.model)
            }
        guard !candidates.isEmpty else { return }
        // STICKY fail-over (mirrors the agent loop): once we've moved to a model,
        // keep using it for subsequent units — only advance when IT fails. We
        // realize this by moving the currently-active candidate to the FRONT, so
        // synthWithFailover tries it first and only walks forward on its failure.
        if let active = stickyCandidateKey,
           let i = candidates.firstIndex(where: { $0.key == active }), i > 0 {
            let c = candidates.remove(at: i)
            candidates.insert(c, at: 0)
        }
        // Drop a stale active label if the active model is no longer a candidate.
        if let active = stickyCandidateKey, !candidates.contains(where: { $0.key == active }) {
            stickyCandidateKey = nil
            activeModelLabel = nil
        }

        for unit in queue where unit.task == nil && unit.audio == nil && !unit.failed {
            guard slots > 0 else { break }
            slots -= 1
            let charCount = unit.text.count
            let seq = unit.seq
            unit.task = Task { [weak self] in
                guard let self else { return }
                let t0 = DispatchTime.now()
                do {
                    // Synthesize at 1× always; speed is applied at PLAYBACK via
                    // AVAudioPlayer.rate. Fails over across group models: each model
                    // gets same-text retries + a split fallback before the next.
                    let (data, used) = try await Self.synthWithFailover(
                        text: unit.text, candidates: candidates, seq: seq)
                    if Task.isCancelled { return }
                    let synthTime = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
                    await MainActor.run {
                        unit.audio = data
                        // Stick to the model that just worked; surface it on the capsule.
                        if self.stickyCandidateKey != used.key {
                            self.stickyCandidateKey = used.key
                            self.activeModelLabel = used.label
                            VoiceLog.log("TTS active model → \(used.label)")
                        }
                        self.recordSynthMetrics(chars: charCount, synthTime: synthTime, wav: data)
                        VoiceLog.log("TTS synth done #\(seq): \(data.count) bytes in \(String(format: "%.2f", synthTime))s")
                        self.pumpPlayback()
                        self.pumpPrefetch()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        // All retries + split fallback exhausted — give up on THIS
                        // unit (mark failed so playback skips it and continues with
                        // the next), and tell the user some content can't be read.
                        unit.failed = true
                        self.synthFailureTick &+= 1   // flash the control red
                        self.logger.error("TTS synth failed #\(seq): \(error.localizedDescription)")
                        VoiceLog.log("TTS synth FAILED #\(seq) after all retries + split: \(error.localizedDescription)")
                        MinisToast.show(AppLocalized("Voice synthesis failed — some content may not be read aloud."),
                                        systemImage: "exclamationmark.triangle.fill")
                        self.pumpPlayback()
                        self.pumpPrefetch()
                    }
                }
            }
        }
        refreshSynthesizingState()
    }

    // MARK: - Synthesis with retry / split fallback

    /// Fail over across Model-Group TTS candidates: try each model's
    /// `synthWithRetry` (same-text retries + split) in order; return the first
    /// success. Throws only when EVERY candidate has been exhausted — that's the
    /// only case the caller surfaces a failure toast to the user.
    nonisolated private static func synthWithFailover(
        text: String, candidates: [Candidate], seq: Int
    ) async throws -> (Data, Candidate) {
        var lastError: Error?
        for (i, c) in candidates.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            do {
                let data = try await synthWithRetry(text: text, model: c.modelId, voice: c.voiceId, resolvedModel: c.resolvedModel, provider: c.provider, seq: seq)
                if i > 0 { VoiceLog.log("TTS #\(seq): succeeded on fail-over model \(i + 1)/\(candidates.count) (\(c.label))") }
                return (data, c)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if i + 1 < candidates.count {
                    VoiceLog.log("TTS #\(seq): model \(i + 1)/\(candidates.count) (\(c.label)) failed — failing over to next")
                }
            }
        }
        throw lastError ?? VoiceProviderError.parseError("All TTS candidates failed")
    }

    /// Synthesize `text`, retrying the SAME text `synthRetriesSameText` times with
    /// backoff; if it still fails, SPLIT the text into smaller sentence chunks and
    /// synthesize+concatenate those (a too-long / partially-rejected batch often
    /// succeeds in smaller pieces). Throws only if even the split fallback fails.
    ///
    /// [T-ios-tts-voice-never-sent] `voice` is passed through to every
    /// `VoiceOutputRequest` built here. Both construction sites must set it —
    /// the chunked fallback below is a real playback path, not a diagnostic
    /// one, so omitting it there would keep the default-voice bug alive for any
    /// reply long enough to be split.
    nonisolated private static func synthWithRetry(
        text: String, model: String?, voice: String?, resolvedModel: LLMModel? = nil,
        provider: any VoiceOutputCapable, seq: Int
    ) async throws -> Data {
        var lastError: Error?
        // Phase 1: retry the same text.
        for attempt in 0...synthRetriesSameText {
            if Task.isCancelled { throw CancellationError() }
            do {
                return try await provider.synthesize(VoiceOutputRequest(input: text, model: model, voice: voice, resolvedModel: resolvedModel))
            } catch {
                lastError = error
                VoiceLog.log("TTS synth retry #\(seq) attempt \(attempt + 1)/\(synthRetriesSameText + 1) failed: \(error.localizedDescription)")
                let backoff = synthRetryBackoff * Double(attempt + 1)
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1e9))
            }
        }
        // Phase 2: split into smaller chunks and synthesize each, then concatenate.
        let chunks = splitForRetry(text)
        guard chunks.count > 1 else { throw lastError ?? VoiceProviderError.parseError("synth failed") }
        VoiceLog.log("TTS synth #\(seq): retrying as \(chunks.count) smaller chunks")
        var pieces: [Data] = []
        for (i, chunk) in chunks.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            var ok = false
            for attempt in 0...synthRetriesSameText {
                do {
                    let d = try await provider.synthesize(VoiceOutputRequest(input: chunk, model: model, voice: voice, resolvedModel: resolvedModel))
                    pieces.append(d); ok = true; break
                } catch {
                    lastError = error
                    VoiceLog.log("TTS synth #\(seq) chunk \(i + 1)/\(chunks.count) attempt \(attempt + 1) failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(synthRetryBackoff * 1e9))
                }
            }
            guard ok else { throw lastError ?? VoiceProviderError.parseError("chunk synth failed") }
        }
        return concatWav(pieces)
    }

    /// Split text into ≤`synthSplitChunkChars` chunks on sentence/pause boundaries.
    nonisolated private static func splitForRetry(_ text: String) -> [String] {
        let enders: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";", "，", ",", "、", "\n"]
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if cur.count >= synthSplitChunkChars && enders.contains(ch) {
                out.append(cur); cur = ""
            }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
        return out.isEmpty ? [text] : out
    }

    /// Concatenate multiple WAV blobs into one (uses the first header, sums data).
    /// Assumes identical format (same model → same 24 kHz/16-bit mono).
    nonisolated private static func concatWav(_ wavs: [Data]) -> Data {
        guard let first = wavs.first else { return Data() }
        guard wavs.count > 1 else { return first }
        var pcm = Data()
        for w in wavs where w.count > 44 { pcm.append(w.subdata(in: 44..<w.count)) }
        var out = first.subdata(in: 0..<44)   // reuse header, then fix sizes
        let dataSize = UInt32(pcm.count).littleEndian
        let riffSize = UInt32(36 + pcm.count).littleEndian
        out.replaceSubrange(4..<8, with: withUnsafeBytes(of: riffSize) { Data($0) })
        out.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize) { Data($0) })
        out.append(pcm)
        return out
    }

    /// Play the front unit if it's ready and nothing is currently playing.
    private func pumpPlayback() {
        // Honor an external-audio pause: while paused (e.g. another app is
        // recording) we must NOT start the next queued unit, even though there
        // is no live `player` — otherwise a unit whose synthesis completes
        // mid-recording would start playing under the recorder. `resume()`
        // re-enters here when the pause lifts.
        guard !isPaused else { return }
        guard player == nil else { return }            // already playing
        guard let front = queue.first else {           // queue drained
            if isPlaying { isPlaying = false }
            return
        }
        // Skip a failed front unit.
        if front.failed {
            queue.removeFirst()
            pumpPlayback()
            return
        }
        guard let audio = front.audio else { return }  // front not generated yet

        queue.removeFirst()
        playingSeq = front.seq
        playingSessionId = front.ownerSessionId
        do {
            try activatePlaybackSession()
            let p = try AVAudioPlayer(data: audio)
            p.delegate = self
            // Real-time variable speed: rate is applied at PLAYBACK (not synthesis),
            // so changing speed takes effect on the CURRENTLY-playing audio.
            p.enableRate = true
            p.rate = VoiceOutputPreferences.speedMultiplier
            p.prepareToPlay()
            p.play()
            player = p
            isPlaying = true
            VoiceLog.log(String(format: "TTS ▶︎ play #%d owner=%@ dur=%.2fs rate=%.2f queueAhead=%d bufferedAfter=%.2fs",
                front.seq, String(front.ownerSessionId.prefix(8)), p.duration, p.rate, queue.count, bufferedAudioSeconds))
        } catch {
            logger.error("TTS play failed #\(front.seq): \(error.localizedDescription)")
            playingSeq = -1
            playingSessionId = nil
            pumpPlayback()                              // try next
        }
        pumpPrefetch()
    }

    private func activatePlaybackSession() throws {
        // Session is owned by AudioSessionCoordinator — declare the reply-TTS intent
        // (idempotent; AIChatViewModel.speak* already did). It applies the
        // `.playback/.spokenAudio/.duckOthers` profile.
        AudioSessionCoordinator.shared.begin(.replyTTS)
    }
}

extension VoiceOutputPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // Only react if THIS player is still the current one — stopAll() or a
            // newly-started unit may have already replaced it.
            guard self.player === finished else { return }
            let finishedSeq = self.playingSeq
            self.player = nil
            self.playingSeq = -1
            self.playingSessionId = nil
            // Detect an UNDER-RUN: audio finished but the next unit isn't ready yet
            // (still generating) → a gap. Logged so the dynamic window can be tuned.
            let nextReady = self.queue.first?.audio != nil
            let generating = self.queue.contains { $0.task != nil && $0.audio == nil && !$0.failed }
            if !self.queue.isEmpty && !nextReady && generating {
                VoiceLog.log("TTS ⚠︎ UNDER-RUN after #\(finishedSeq): next unit not ready (queue=\(self.queue.count), still synthesizing)")
            } else {
                VoiceLog.log("TTS ■ finished #\(finishedSeq) (queue=\(self.queue.count) buffered=\(String(format: "%.2f", self.bufferedAudioSeconds))s)")
            }
            self.pumpPlayback()
            // Nothing left and nothing generating → release the session (guarded
            // so it never deactivates a recording session).
            if self.queue.isEmpty && self.player == nil && !generating {
                self.releaseSessionIfSafe()
            }
        }
    }
}

// MARK: - Desktop pet mailbox

private struct PetSpeechRequest: Equatable {
    let id: String
    let createdAt: TimeInterval
    let text: String
}

private enum PetSpeechMailbox {
    static let lifetime: TimeInterval = 30
    static let jsonLimit = 8_192
    static let audioLimit = 15_000_000
    static let textLimit = 300
    static let clockSkew: TimeInterval = 3
    static let requestName = "request.json"

    /// Keep this mailbox outside the File Provider's shared domain.
    static func openDirectory() -> Int32 {
        guard let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedContainerStore.appGroupID
        ) else { return -1 }
        let base = group.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard base >= 0 else { return -1 }
        defer { close(base) }
        let folder = "MinisPetSpeech"
        guard mkdirat(base, folder, mode_t(0o700)) == 0 || errno == EEXIST else { return -1 }
        let fd = openat(base, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    static func readRequest(from directory: Int32) -> PetSpeechRequest? {
        let fd = openat(directory, requestName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size > 0,
              info.st_size <= off_t(jsonLimit) else { return nil }
        var body = Data(count: Int(info.st_size))
        let complete = body.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ptr = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(fd, ptr.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            var extra: UInt8 = 0
            var tail: Int
            repeat { tail = Darwin.read(fd, &extra, 1) } while tail < 0 && errno == EINTR
            return tail == 0
        }
        guard complete, let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let schema = number(object["schema"]), schema == 1,
              let id = object["request_id"] as? String, id.utf8.count == 36, UUID(uuidString: id)?.uuidString == id,
              let created = number(object["created_at"]), created > 0,
              let text = object["text"] as? String, (2...textLimit).contains(text.utf16.count) else { return nil }
        let age = Date().timeIntervalSince1970 - created
        guard age >= -clockSkew, age < lifetime else { return nil }
        return PetSpeechRequest(id: id, createdAt: created, text: text)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    /// Persist only the UUID, before calling a provider. A resumed app must
    /// not synthesize or bill the same live request twice.
    static func claim(_ id: String, in directory: Int32) -> Bool {
        let fd = openat(directory, "seen-\(id).marker", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fsync(fd) == 0
    }

    static func write(_ data: Data, named name: String, in directory: Int32) -> Bool {
        let temporary = ".speech-\(UUID().uuidString).tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return false }
        defer {
            close(fd)
            unlinkat(directory, temporary, 0)
        }
        let complete = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            guard let ptr = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, ptr.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return complete && fsync(fd) == 0 && renameat(directory, temporary, directory, name) == 0
    }

    static func prune(in directory: Int32) {
        let copy = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { return }
        guard let list = fdopendir(copy) else { close(copy); return }
        defer { closedir(list) }
        let cutoff = Date().timeIntervalSince1970 - 120
        for _ in 0..<512 {
            guard let item = readdir(list) else { break }
            let name = withUnsafeBytes(of: item.pointee.d_name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard isGeneratedFilename(name) else { continue }
            var info = stat()
            if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
               info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
               Double(info.st_mtimespec.tv_sec) < cutoff {
                unlinkat(directory, name, 0)
            }
        }
    }

    private static func isGeneratedFilename(_ name: String) -> Bool {
        let formats = [("seen-", ".marker"), ("response-", ".json"), ("audio-", ".mp3"), ("audio-", ".wav"),
                       (".speech-", ".tmp"), (".request-", ".tmp")]
        for (prefix, suffix) in formats where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            if id.utf8.count == 36 && UUID(uuidString: id)?.uuidString == id { return true }
        }
        return false
    }
}

private extension PetSpeechMailbox {
    static func audioSuffix(_ data: Data) -> String? {
        guard (4...audioLimit).contains(data.count) else { return nil }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> String? in
            if isWAV(bytes) { return "wav" }
            if isMP3(bytes) { return "mp3" }
            return nil
        }
    }

    static func isWAV(_ bytes: UnsafeRawBufferPointer) -> Bool {
        func word(at offset: Int) -> UInt32 {
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        // RIFF and WAVE in little endian. Non-PCM variants are left to the player.
        guard bytes.count > 44, word(at: 0) == 0x46464952, word(at: 8) == 0x45564157 else { return false }
        let declared = word(at: 4)
        guard declared == UInt32.max || Int(declared) == bytes.count - 8 else { return false }
        var offset = 12
        var hasFormat = false
        for _ in 0..<128 {
            let available = bytes.count - offset - 8
            guard available >= 0 else { return false }
            let kind = word(at: offset)
            let length = word(at: offset + 4)
            if kind == 0x61746164 { // data
                return hasFormat && length > 0 && available > 0 && (length == UInt32.max || Int(length) <= available)
            }
            if kind == 0x20746d66 { // fmt
                guard length >= 16 else { return false }
                hasFormat = true
            }
            let padded = Int(length) + Int(length & 1)
            guard padded <= available else { return false }
            offset += 8 + padded
        }
        return false
    }

    static func isMP3(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let rates = [44100, 48000, 32000]
        let mpeg1 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let mpeg2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        var offset = 0
        if bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33 { // ID3
            guard bytes.count >= 10, (2...4).contains(bytes[3]) else { return false }
            for i in 6..<10 {
                guard bytes[i] & 0x80 == 0 else { return false }
                offset = (offset << 7) | Int(bytes[i])
            }
            offset += bytes[3] == 4 && bytes[5] & 0x10 != 0 ? 20 : 10
        }
        guard offset <= bytes.count - 4 else { return false }
        let second = bytes[offset + 1]
        let third = bytes[offset + 2]
        let version = (second >> 3) & 3
        let bitRate = Int(third >> 4)
        let rate = Int((third >> 2) & 3)
        guard bytes[offset] == 0xff, second & 0xe6 == 0xe2,
              version != 1, (1...14).contains(bitRate), rate < 3 else { return false }
        let hz = rates[rate] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        let frame = (version == 3 ? 144000 * mpeg1[bitRate] : 72000 * mpeg2[bitRate]) / hz
        return bytes.count - offset >= frame + Int((third >> 1) & 1)
    }
}
