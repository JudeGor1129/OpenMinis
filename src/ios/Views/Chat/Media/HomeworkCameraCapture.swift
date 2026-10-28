@preconcurrency import AVFoundation
import AudioToolbox
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

struct HomeworkCameraFrame: @unchecked Sendable {
    /// Upright portrait CGImage; ROI coordinates are top-left normalized pixels.
    let image: CGImage
    let signature: [UInt8]
    let region: CGRect
    let capturedAt: TimeInterval
    /// At most one delivery can be waiting for the main actor.
    let acknowledge: @Sendable () -> Void
}

/// One disposable foreground capture run. All configuration/start/stop work is
/// serial; both delegates share a sample queue. No recording or network access.
/// Stop invalidates delegate delivery synchronously, then closes the hardware
/// on sessionQueue. A stopped instance must never be reused.
final class HomeworkCameraCapture: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private static let hardwareQueue = DispatchQueue(label: "com.openminis.homework.session")
    private let sessionQueue = HomeworkCameraCapture.hardwareQueue
    private let sampleQueue = DispatchQueue(label: "com.openminis.homework.samples")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    // Guarded by lock; all other mutable state belongs to sampleQueue.
    private var accepting = false
    private var frameOutstanding = false
    private var closed = false
    private var region: CGRect
    private var lastFrame = -Double.infinity
    private var loudDuration = 0.0
    private var quietDuration = 0.0
    private var voiceActive = false
    private let onFrame: @Sendable (HomeworkCameraFrame) -> Void
    private let onVoiceActivity: @Sendable (Bool) -> Void
    private let onAudio: @Sendable (CMSampleBuffer) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(region: CGRect,
         onFrame: @escaping @Sendable (HomeworkCameraFrame) -> Void,
         onVoiceActivity: @escaping @Sendable (Bool) -> Void,
         onAudio: @escaping @Sendable (CMSampleBuffer) -> Void = { _ in },
         onFailure: @escaping @Sendable (String) -> Void) {
        self.region = HomeworkHintPolicy.normalizedRegion(region)
        self.onFrame = onFrame
        self.onVoiceActivity = onVoiceActivity
        self.onAudio = onAudio
        self.onFailure = onFailure
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sessionFailed(_:)),
                       name: AVCaptureSession.runtimeErrorNotification, object: session)
        nc.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                       name: AVCaptureSession.wasInterruptedNotification, object: session)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setRegion(_ value: CGRect) {
        lock.lock()
        region = HomeworkHintPolicy.normalizedRegion(value)
        lock.unlock()
    }

    func start(completion: @escaping @Sendable (String?) -> Void) {
        sessionQueue.async { [self] in
            guard !isClosed else { completion("相机启动已取消。"); return }
            do {
                try configure()
                guard !isClosed else { completion("相机启动已取消。"); return }
                sampleQueue.sync { resetSampleState() }
                session.startRunning()
                lock.lock()
                let started = session.isRunning && !closed
                accepting = started
                lock.unlock()
                if started { completion(nil) }
                else {
                    if session.isRunning { session.stopRunning() }
                    completion("相机未启动或操作已取消。")
                }
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        closed = true
        accepting = false
        lock.unlock()
        // Retain the backend until the queued hardware shutdown actually ends.
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            for output in session.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
            }
            completion()
        }
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func snapshot() -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return accepting && !closed ? region : nil
    }

    private func configure() throws {
        session.beginConfiguration()
        var complete = false
        defer {
            if !complete {
                for output in session.outputs { session.removeOutput(output) }
                for input in session.inputs { session.removeInput(input) }
            }
            session.commitConfiguration()
        }
        // The shared coordinator, not AVCaptureSession, owns the audio profile.
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        else { session.sessionPreset = .high }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video, position: .back),
              let mic = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.message("后置摄像头或麦克风不可用。")
        }
        let videoInput = try AVCaptureDeviceInput(device: camera)
        let audioInput = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(videoInput) else {
            throw CaptureError.message("无法添加后置摄像头。")
        }
        session.addInput(videoInput)
        guard session.canAddInput(audioInput) else {
            throw CaptureError.message("无法添加麦克风。")
        }
        session.addInput(audioInput)
        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        let audio = AVCaptureAudioDataOutput()
        guard session.canAddOutput(video) else {
            throw CaptureError.message("无法输出相机静帧。")
        }
        session.addOutput(video)
        guard session.canAddOutput(audio) else {
            throw CaptureError.message("无法检测麦克风声音活动。")
        }
        session.addOutput(audio)
        video.setSampleBufferDelegate(self, queue: sampleQueue)
        audio.setSampleBufferDelegate(self, queue: sampleQueue)
        guard let connection = video.connection(with: .video), connection.isVideoOrientationSupported else {
            throw CaptureError.message("相机不支持竖向静帧输出。")
        }
        connection.videoOrientation = .portrait
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        // Reduce sensor work when supported; analysis itself remains 2.5 fps.
        if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= 10 && $0.maxFrameRate >= 10
        }) {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 10)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 10)
            camera.unlockForConfiguration()
        }
        complete = true
    }

    private enum CaptureError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    @objc private func sessionFailed(_ note: Notification) {
        reportFailure("相机采集异常，已暂停；请重新打开相机。")
    }
    @objc private func sessionInterrupted(_ note: Notification) {
        reportFailure("相机采集被系统中断，已暂停；不会自动恢复。")
    }
    private func reportFailure(_ message: String) {
        lock.lock()
        let shouldReport = accepting && !closed
        accepting = false
        lock.unlock()
        if shouldReport { onFailure(message) }
    }

    private func acknowledgeFrame() {
        lock.lock(); frameOutstanding = false; lock.unlock()
    }

    private func resetSampleState() {
        lastFrame = -Double.infinity
        loudDuration = 0
        quietDuration = 0
        voiceActive = false
    }

    private func makePortraitImage(_ buffer: CVPixelBuffer) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        if image.extent.width > image.extent.height { image = image.oriented(.right) }
        return context.createCGImage(image, from: image.extent)
    }

    /// CGImage pixel rectangles and the SwiftUI overlay both use a top-left
    /// normalized region in this app. Keep this conversion in one place.
    private func pixelRect(for region: CGRect, image: CGImage) -> CGRect {
        HomeworkHintPolicy.pixelRect(region: region,
            imageSize: CGSize(width: image.width, height: image.height))
    }

    private func signature(for image: CGImage, region: CGRect) -> [UInt8] {
        guard let cropped = image.cropping(to: pixelRect(for: region, image: image)) else { return [] }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: 32 * 32)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: 32, height: 32,
                                         bitsPerComponent: 8, bytesPerRow: 32,
                                         space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            bitmap.interpolationQuality = .low
            bitmap.draw(cropped, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        return drawn ? pixels : []
    }

    private func audioEnergy(from sampleBuffer: CMSampleBuffer) -> (rms: Double, duration: Double)? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                          lengthAtOffsetOut: &length,
                                          totalLengthOut: &total,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, total > 0, length == total,
              asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0 else { return nil }
        let bits = Int(asbd.mBitsPerChannel)
        let floatingPoint = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard (bits == 16 && !floatingPoint) || (bits == 32 && floatingPoint) else { return nil }
        let sampleCount = length / (bits / 8)
        guard sampleCount > 0 else { return nil }
        let bytes = UnsafeRawPointer(pointer)
        var sum = 0.0
        if bits == 16 {
            let samples = bytes.bindMemory(to: Int16.self, capacity: sampleCount)
            for index in 0..<sampleCount {
                let value = Double(samples[index]) / 32768.0
                sum += value * value
            }
        } else {
            let samples = bytes.bindMemory(to: Float.self, capacity: sampleCount)
            for index in 0..<sampleCount {
                let value = max(-1.0, min(1.0, Double(samples[index])))
                sum += value * value
            }
        }
        let frameCount = max(1, CMSampleBufferGetNumSamples(sampleBuffer))
        return (sqrt(sum / Double(sampleCount)),
                Double(frameCount) / max(1, asbd.mSampleRate))
    }
}

extension HomeworkCameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let region = snapshot() else { return }
        if output is AVCaptureAudioDataOutput {
            onAudio(sampleBuffer)
            guard let energy = audioEnergy(from: sampleBuffer) else { return }
            let threshold = 0.035
            if voiceActive {
                if energy.rms < threshold {
                    quietDuration += energy.duration
                    loudDuration = 0
                    if quietDuration >= 1.0 {
                        voiceActive = false
                        quietDuration = 0
                        onVoiceActivity(false)
                    }
                } else {
                    quietDuration = 0
                }
            } else if energy.rms >= threshold {
                loudDuration += energy.duration
                quietDuration = 0
                if loudDuration >= 0.35 {
                    voiceActive = true
                    loudDuration = 0
                    onVoiceActivity(true)
                }
            } else {
                loudDuration = 0
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 0.4 else { return }
        lock.lock()
        guard !frameOutstanding, accepting, !closed else { lock.unlock(); return }
        frameOutstanding = true
        lock.unlock()
        lastFrame = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = makePortraitImage(buffer) else { acknowledgeFrame(); return }
        let pixels = signature(for: image, region: region)
        guard pixels.count == 1024, snapshot() != nil else { acknowledgeFrame(); return }
        onFrame(HomeworkCameraFrame(image: image, signature: pixels,
            region: region, capturedAt: now,
            acknowledge: { [weak self] in self?.acknowledgeFrame() }))
    }
}
