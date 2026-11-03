import AVFoundation
import Testing
@testable import FineTune

@Suite("Delay calibration — matched filtering and validation")
struct DelayCalibrationTests {
    @Test("Temporary AVAudioEngine wrappers do not appear as calibration outputs")
    func filtersInternalWrappers() {
        #expect(AudioDeviceMonitor.isInternalAggregate(name: "CADefaultDeviceAggregate-1234-0", isAggregate: true))
        #expect(AudioDeviceMonitor.isInternalAggregate(name: "FineTuneDelay-1234", isAggregate: true))
    }

    @Test("User-created multi-output devices remain selectable")
    func preservesUserAggregates() {
        #expect(!AudioDeviceMonitor.isInternalAggregate(name: "Multi-Output Device", isAggregate: true))
        #expect(!AudioDeviceMonitor.isInternalAggregate(name: "My Studio Aggregate", isAggregate: true))
    }

    @Test("A name prefix alone never hides a physical or virtual non-aggregate device")
    func preservesNonAggregates() {
        #expect(!AudioDeviceMonitor.isInternalAggregate(name: "FineTune-USB", isAggregate: false))
        #expect(!AudioDeviceMonitor.isInternalAggregate(name: "BlackHole 2ch", isAggregate: false))
    }

    private func recording(rate: Double = 8_000, first: [Double] = [0.08, 0.08, 0.08],
                           second: [Double] = [0.31, 0.31, 0.31], inverted: Bool = false,
                           echo: Bool = false) -> [Float] {
        var state: UInt64 = 42
        var samples = (0..<Int(16 * rate)).map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return (Float(state >> 40) / Float(1 << 24) - 0.5) * 0.0008
        }
        for device in 0..<2 {
            let template = CalibrationProbe.chirp(rate: rate, second: device == 1)
            for (index, slot) in CalibrationProbe.slots[device].enumerated() {
                let delay = device == 0 ? first[index] : second[index]
                let start = Int(((0.2 + slot + delay) * rate).rounded())
                for i in template.indices {
                    let gain: Float = (device == 0 ? 0.06 : 0.018) * (inverted ? -1 : 1)
                    samples[start + i] += template[i] * gain
                    if echo { samples[start + i + Int(rate * 0.2)] += template[i] * gain }
                }
            }
        }
        return samples
    }

    private func analyze(_ samples: [Float], rate: Double = 8_000) throws -> DelayCalibrationResult {
        try DelayCalibrationAnalysis.analyze(samples: samples, sampleRate: rate,
                                             recordingStart: 100, playbackStart: 100.2,
                                             firstUID: "speaker", secondUID: "airpods")
    }

    @Test("Finds the 230 ms relative delay despite unequal gain, noise and polarity inversion", arguments: [false, true])
    func measured230(inverted: Bool) throws {
        let result = try analyze(recording(inverted: inverted))
        #expect(result.firstMilliseconds == 230)
        #expect(result.secondMilliseconds == 0)
        #expect((result.spreadMilliseconds ?? 100) < 1)
    }

    @Test("Converts 44.1 kHz input without changing the relative delay")
    func differentSampleRate() throws {
        let result = try analyze(recording(rate: 44_100), rate: 44_100)
        #expect(abs(result.firstMilliseconds - 230) <= 1)
    }

    @Test("Delays the other output when the order is reversed")
    func negativeDifference() throws {
        let result = try analyze(recording(first: [0.31, 0.31, 0.31], second: [0.08, 0.08, 0.08]))
        #expect(result.firstMilliseconds == 0)
        #expect(result.secondMilliseconds == 230)
    }

    @Test("A common microphone/capture latency cancels out")
    func commonInputDelay() throws {
        let result = try analyze(recording(first: [0.38, 0.38, 0.38], second: [0.61, 0.61, 0.61]))
        #expect(result.firstMilliseconds == 230)
    }

    @Test("Small repeated jitter uses the median")
    func robustMedian() throws {
        let result = try analyze(recording(first: [0.079, 0.08, 0.084], second: [0.308, 0.31, 0.313]))
        #expect(result.firstMilliseconds == 230)
        #expect((result.spreadMilliseconds ?? 0) >= 4)
    }

    @Test("Refuses inconsistent Bluetooth timing")
    func rejectsJitter() {
        #expect(throws: CalibrationFailure.unstable) {
            try analyze(recording(second: [0.20, 0.31, 0.45]))
        }
    }

    @Test("Refuses an absent or silent microphone")
    func rejectsSilence() {
        #expect(throws: CalibrationFailure.noSignal) { try analyze([Float](repeating: 0, count: 128_000)) }
        #expect(throws: CalibrationFailure.noSignal) { try analyze([]) }
    }

    @Test("Refuses an equally strong delayed echo")
    func rejectsEcho() {
        #expect(throws: CalibrationFailure.ambiguous) { try analyze(recording(echo: true)) }
    }

    @Test("Refuses clipped, non-finite or truncated recordings")
    func rejectsInvalidInput() {
        #expect(throws: CalibrationFailure.clipping) { try analyze([Float](repeating: 1, count: 128_000)) }
        #expect(throws: CalibrationFailure.noSignal) { try analyze([.nan]) }
        #expect(throws: CalibrationFailure.noSignal) { try analyze(Array(recording().prefix(1_000))) }
    }

    @Test("Never clamps an out-of-range result into a seemingly valid calibration")
    func rejectsOutOfRange() {
        #expect(throws: CalibrationFailure.outOfRange) {
            try DelayCalibrationResult.make(method: .acoustic, firstUID: "a", secondUID: "b", difference: 2_001)
        }
        #expect(throws: CalibrationFailure.outOfRange) {
            try DelayCalibrationResult.make(method: .reported, firstUID: "a", secondUID: "a", difference: 0)
        }
    }

    @Test("Probe generation has bounded gain and silent edges")
    func probeGain() {
        let samples = CalibrationProbe.playback()
        #expect(samples.count == 720_000)
        #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 0.162 })
        #expect(samples.first == 0)
        #expect(samples.last == 0)
    }
}

@Suite("Delay calibration — recording and lifecycle")
@MainActor
struct DelayCalibrationLifecycleTests {
    @Test("The microphone callback can run on an audio delivery queue without MainActor isolation")
    func backgroundRecordingCallback() async throws {
        let recording = CalibrationRecording(sampleRate: 48_000)
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            buffer.floatChannelData![0].initialize(repeating: 0.125, count: 480)
            let callback = CalibrationMicrophone.recordingCallback(recording)
            callback(buffer, AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10)))
        }.value
        #expect(try recording.snapshot().samples == [Float](repeating: 0.125, count: 480))
    }

    @Test("Recording copies a channel and retains the hardware capture timestamp")
    func recordingSnapshot() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 480)
        let recording = CalibrationRecording(sampleRate: 48_000)
        recording.append(buffer, time: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10)))
        let snapshot = try recording.snapshot()
        #expect(snapshot.samples == [Float](repeating: 0.25, count: 480))
        #expect(abs(snapshot.start - 10) < 0.001)
    }

    @Test("Capture discontinuities invalidate a measurement")
    func discontinuity() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        buffer.floatChannelData![0].initialize(repeating: 0, count: 480)
        let recording = CalibrationRecording(sampleRate: 48_000)
        recording.append(buffer, time: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10)))
        recording.append(buffer, time: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 10.2)))
        #expect(throws: CalibrationFailure.deviceChanged) { try recording.snapshot() }
    }

    @Test("A failed start releases the busy state without starting audio or requesting permission")
    func deniedCapture() async {
        let model = DelayCalibrationModel()
        let a = AudioDevice(id: 0, uid: "a", name: "a", icon: nil, supportsAutoEQ: false)
        let b = AudioDevice(id: 0, uid: "b", name: "b", icon: nil, supportsAutoEQ: false)
        model.start(first: a, second: b, microphone: nil, acoustic: false,
                    currentDelays: [230, 0], captureAuthorized: false)
        while model.isRunning { await Task.yield() }
        #expect(model.error != nil)
        #expect(model.result == nil)
        #expect(CalibrationSourceProcess.activePID == nil)
    }
}
