import AudioToolbox
import AVFoundation
import Foundation

@Observable
@MainActor
final class DelayCalibrationModel {
    var result: DelayCalibrationResult?
    var error: String?
    private(set) var isRunning = false
    private(set) var phase = "Ready to test"
    private(set) var progress: Double = 0
    private var task: Task<Void, Never>?
    private var resultRates: [Double] = []

    static func usableMicrophones(_ devices: [AudioDevice]) -> [AudioDevice] {
        devices.filter { device in
            let transport = device.id.readTransportType()
            return [.builtIn, .usb, .thunderbolt].contains(transport)
        }
    }

    func estimate(first: AudioDevice, second: AudioDevice) {
        guard !isRunning else { return }
        error = nil
        result = nil
        do {
            result = try .make(method: .reported, firstUID: first.uid, secondUID: second.uid,
                               difference: Self.reportedLatency(second) - Self.reportedLatency(first))
            resultRates = try [first, second].map { try $0.id.readNominalSampleRate() }
        } catch { self.error = error.localizedDescription }
    }

    /// Driver properties are an estimate, not an acoustic measurement. Some
    /// Bluetooth firmware buffering is unreported; never silently apply this.
    private static func reportedLatency(_ device: AudioDevice) throws -> Double {
        let rate = try device.id.readNominalSampleRate()
        guard rate.isFinite, rate > 0 else { throw CalibrationFailure.deviceChanged }
        let latency: UInt32 = try device.id.read(kAudioDevicePropertyLatency, scope: .output, defaultValue: 0)
        let safety: UInt32 = try device.id.read(kAudioDevicePropertySafetyOffset, scope: .output, defaultValue: 0)
        let buffer: UInt32 = try device.id.read(kAudioDevicePropertyBufferFrameSize, defaultValue: 0)
        let streams: [AudioObjectID] = try device.id.readArray(kAudioDevicePropertyStreams, scope: .output, defaultValue: 0)
        let streamLatency = try streams.map { stream -> UInt32 in
            try stream.read(kAudioStreamPropertyLatency, defaultValue: 0)
        }.max() ?? 0
        return (Double(latency) + Double(safety) + Double(buffer) + Double(streamLatency)) / rate * 1000
    }

    func start(first: AudioDevice, second: AudioDevice, microphone: AudioDevice?,
               acoustic: Bool, currentDelays: [Double], captureAuthorized: Bool,
               outputGains: @escaping @MainActor () -> [Float] = { [1, 1] }) {
        guard !isRunning, first.uid != second.uid else { return }
        isRunning = true
        error = nil
        let savedResult = result
        if acoustic { result = nil }
        phase = "Preparing audio devices"
        progress = 0
        task = Task { [weak self] in
            guard let self else { return }
            let playback = CalibrationPlayback()
            let capture = CalibrationMicrophone()
            defer {
                playback.stop()
                capture.stop()
                self.isRunning = false
                self.task = nil
            }
            do {
                guard captureAuthorized else { throw CalibrationFailure.sourceUnavailable }
                if acoustic {
                    guard let microphone,
                          Self.usableMicrophones([microphone]).count == 1 else {
                        throw CalibrationFailure.inputUnavailable
                    }
                    let granted: Bool
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .authorized: granted = true
                    case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
                    default: granted = false
                    }
                    try Task.checkCancellation()
                    guard granted else { throw CalibrationFailure.permission }
                }
                try await playback.prepare(first: first, second: second, delays: acoustic ? [0, 0] : currentDelays)
                playback.updateGains(outputGains())
                if acoustic, let microphone { try capture.start(device: microphone) }
                let rates = [first, second].map { try? $0.id.readNominalSampleRate() }
                let tick = try playback.play(acoustic: acoustic)
                let started = AVAudioTime.seconds(forHostTime: tick)
                for _ in 0..<160 {
                    try Task.checkCancellation()
                    let elapsed = AVAudioTime.seconds(forHostTime: mach_absolute_time()) - started
                    self.progress = min(1, max(0, elapsed / CalibrationProbe.sessionDuration))
                    self.phase = acoustic ? (elapsed < 7 ? "Measuring first output" : "Measuring second output") : "Playing synchronized test sounds"
                    playback.updateGains(outputGains())
                    if acoustic, elapsed >= 7 { playback.switchToSecond() }
                    for (index, device) in [first, second].enumerated() {
                        guard device.id.isDeviceAlive(), (try? device.id.readDeviceUID()) == device.uid,
                              (try? device.id.readNominalSampleRate()) == rates[index] else {
                            throw CalibrationFailure.deviceChanged
                        }
                    }
                    if let microphone, acoustic, !microphone.id.isDeviceAlive() { throw CalibrationFailure.deviceChanged }
                    if elapsed >= CalibrationProbe.sessionDuration { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                playback.stop()
                capture.stop()
                try Task.checkCancellation()
                if acoustic, let recording = capture.recording {
                    self.phase = "Analyzing recorded test sounds"
                    let snapshot = try recording.snapshot()
                    let rate = recording.sampleRate
                    self.result = try await Task.detached(priority: .userInitiated) {
                        try DelayCalibrationAnalysis.analyze(samples: snapshot.samples, sampleRate: rate,
                                                             recordingStart: snapshot.start, playbackStart: started,
                                                             firstUID: first.uid, secondUID: second.uid)
                    }.value
                    try Task.checkCancellation()
                    self.resultRates = rates.compactMap { $0 }
                }
                self.phase = "Test complete"
                self.progress = 1
            } catch is CancellationError {
                self.result = acoustic ? nil : savedResult
                self.phase = "Test stopped"
            } catch {
                self.result = acoustic ? nil : savedResult
                self.error = error.localizedDescription
                self.phase = "Test stopped"
            }
        }
    }

    func cancel() { task?.cancel() }
    func clear() { cancel(); result = nil; error = nil }

    func validateResult(first: AudioDevice, second: AudioDevice) throws {
        guard let result, result.firstUID == first.uid, result.secondUID == second.uid,
              resultRates.count == 2 else { throw CalibrationFailure.deviceChanged }
        for (index, device) in [first, second].enumerated() {
            guard device.id.isDeviceAlive(), (try? device.id.readDeviceUID()) == device.uid,
                  (try? device.id.readNominalSampleRate()) == resultRates[index] else {
                throw CalibrationFailure.deviceChanged
            }
        }
    }
}
