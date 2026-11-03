import Accelerate
import Foundation

nonisolated enum CalibrationTestLevel {
    static let defaultValue = 0.2
    static let range = 0.1...1.0
    static func sanitize(_ value: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaultValue
    }
    static func gain(level: Double, deviceGain: Float, muted: Bool) -> Float {
        guard !muted, deviceGain.isFinite else { return 0 }
        return Float(sanitize(level)) * min(1, max(0, deviceGain))
    }
}

/// Signal generation and analysis contain no device or settings side effects.
nonisolated enum CalibrationProbe {
    static let sampleRate = 48_000.0
    static let analysisRate = 8_000.0
    static let duration = 0.080
    static let slots: [[Double]] = [[1, 3, 5], [8.5, 10.5, 12.5]]
    static let sessionDuration = 15.0

    static func chirp(rate: Double, second: Bool) -> [Float] {
        let count = Int((duration * rate).rounded())
        return (0..<count).map { index in
            let t = Double(index) / rate
            let start = second ? 2_900.0 : 900.0
            let end = second ? 900.0 : 2_900.0
            let phase = 2 * Double.pi * (start * t + (end - start) * t * t / (2 * duration))
            let envelope = pow(sin(Double.pi * Double(index) / Double(count - 1)), 2)
            return Float(sin(phase) * envelope)
        }
    }

    static func playback() -> [Float] {
        var samples = [Float](repeating: 0, count: Int(sessionDuration * sampleRate))
        // A quiet pilot keeps Bluetooth and FineTune's soft-start gate awake.
        for i in samples.indices {
            let edge = min(1, min(Double(i), Double(samples.count - i - 1)) / (sampleRate * 0.1))
            samples[i] = Float(sin(2 * .pi * 400 * Double(i) / sampleRate) * 0.002 * edge)
        }
        for device in 0..<2 {
            let probe = chirp(rate: sampleRate, second: device == 1)
            for slot in slots[device] {
                let start = Int(slot * sampleRate)
                // Output-specific test gains default to 20%, preserving the old
                // probe level, with up to 5× headroom for quiet AirPods pickup.
                for i in probe.indices { samples[start + i] += 0.8 * probe[i] }
            }
        }
        return samples
    }
}

nonisolated struct DelayCalibrationResult: Sendable {
    enum Method: Sendable { case acoustic, reported }
    let method: Method
    let firstUID: String
    let secondUID: String
    let firstMilliseconds: Double
    let secondMilliseconds: Double
    let spreadMilliseconds: Double?
    let minimumCorrelation: Double?

    static func make(method: Method, firstUID: String, secondUID: String,
                     difference: Double, spread: Double? = nil, correlation: Double? = nil) throws -> Self {
        guard firstUID != secondUID, difference.isFinite,
              abs(difference) <= OutputDelayControl.maximumMilliseconds else {
            throw CalibrationFailure.outOfRange
        }
        return Self(method: method, firstUID: firstUID, secondUID: secondUID,
                    firstMilliseconds: max(0, difference).rounded(),
                    secondMilliseconds: max(0, -difference).rounded(),
                    spreadMilliseconds: spread, minimumCorrelation: correlation)
    }
}

nonisolated enum CalibrationFailure: Error, LocalizedError {
    case noSignal, unstable, ambiguous, clipping, outOfRange, inputUnavailable, permission, sourceUnavailable, deviceChanged
    var errorDescription: String? {
        let key: String
        switch self {
        case .noSignal: key = "The test sound was too quiet. Move the AirPods sound outlet closer to the selected microphone, check both output volumes, and try again."
        case .unstable: key = "Repeated measurements did not agree. Pause other audio, keep the microphone still, and try again."
        case .ambiguous: key = "Echoes or background audio made the result ambiguous. Move closer and test in a quiet room."
        case .clipping: key = "The microphone recording clipped. Lower the output volume or move the microphone farther away."
        case .outOfRange: key = "The measured difference is outside the supported 0–2000 ms compensation range."
        case .inputUnavailable: key = "Choose a wired or USB microphone. AirPods and other Bluetooth microphones cannot measure normal Bluetooth playback latency reliably."
        case .permission: key = "Microphone access is required for acoustic calibration. Enable it in System Settings → Privacy & Security → Microphone."
        case .sourceUnavailable: key = "The test audio source could not start. Check audio capture permission and reconnect the selected devices."
        case .deviceChanged: key = "An audio device disconnected or changed format. Select the devices again and repeat the test."
        }
        return L10n.string(key)
    }
}

nonisolated enum DelayCalibrationAnalysis {
    struct Detection: Sendable { let offset: Double; let correlation: Double }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Normalized matched filtering at 8 kHz. Per-window normalization prevents
    /// a louder unrelated transient from winning just because of its amplitude.
    static func detect(samples: [Float], template: [Float], expected: Double) throws -> Detection {
        let rate = CalibrationProbe.analysisRate
        let first = max(0, Int((expected - 0.12) * rate))
        let last = min(samples.count - template.count, Int((expected + 1.5) * rate))
        guard first <= last, !template.isEmpty else { throw CalibrationFailure.noSignal }
        let count = last - first + 1
        var matches = [Float](repeating: 0, count: count)
        samples.withUnsafeBufferPointer { signal in
            template.withUnsafeBufferPointer { probe in
                matches.withUnsafeMutableBufferPointer { output in
                    vDSP_conv(signal.baseAddress! + first, 1, probe.baseAddress!, 1,
                              output.baseAddress!, 1, vDSP_Length(count), vDSP_Length(template.count))
                }
            }
        }
        let probeEnergy = template.reduce(0.0) { $0 + Double($1 * $1) }
        var energy = samples[first..<(first + template.count)].reduce(0.0) { $0 + Double($1 * $1) }
        var scores = [Double](repeating: 0, count: count)
        for i in 0..<count {
            scores[i] = energy > 1e-9 ? abs(Double(matches[i])) / sqrt(energy * probeEnergy) : 0
            if i + 1 < count {
                energy += Double(samples[first + i + template.count] * samples[first + i + template.count])
                energy -= Double(samples[first + i] * samples[first + i])
                energy = max(0, energy)
            }
        }
        let best = scores.indices.max(by: { scores[$0] < scores[$1] })!
        guard scores[best] >= 0.32 else { throw CalibrationFailure.noSignal }
        let exclusion = Int(0.045 * rate)
        let rival = scores.indices.filter { abs($0 - best) > exclusion }.map { scores[$0] }.max() ?? 0
        guard rival < scores[best] * 0.88 else { throw CalibrationFailure.ambiguous }
        return Detection(offset: Double(first + best) / rate - expected, correlation: scores[best])
    }

    static func analyze(samples: [Float], sampleRate: Double, recordingStart: Double,
                        playbackStart: Double, firstUID: String, secondUID: String) throws -> DelayCalibrationResult {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              recordingStart.isFinite, playbackStart.isFinite, !samples.isEmpty,
              samples.allSatisfy({ $0.isFinite }) else { throw CalibrationFailure.noSignal }
        let clipped = samples.filter { abs($0) >= 0.99 }.count
        guard Double(clipped) / Double(samples.count) < 0.005 else { throw CalibrationFailure.clipping }
        // Linear resampling is adequate below 2.9 kHz; measurement uses a
        // normalized chirp, not raw onset thresholds or a wall-clock stopwatch.
        let count = Int(Double(samples.count) * CalibrationProbe.analysisRate / sampleRate)
        let reduced: [Float] = (0..<count).map { index in
            let position = Double(index) * sampleRate / CalibrationProbe.analysisRate
            let lo = Int(position)
            let hi = min(samples.count - 1, lo + 1)
            return samples[lo] + (samples[hi] - samples[lo]) * Float(position - Double(lo))
        }
        var detections: [[Detection]] = []
        for device in 0..<2 {
            let template = CalibrationProbe.chirp(rate: CalibrationProbe.analysisRate, second: device == 1)
            detections.append(try CalibrationProbe.slots[device].map { slot in
                try detect(samples: reduced, template: template, expected: playbackStart - recordingStart + slot)
            })
        }
        let spreads = detections.map { group in
            (group.map(\.offset).max()! - group.map(\.offset).min()!) * 1000
        }
        guard spreads.allSatisfy({ $0 <= 12 }) else { throw CalibrationFailure.unstable }
        let difference = (median(detections[1].map(\.offset)) - median(detections[0].map(\.offset))) * 1000
        return try .make(method: .acoustic, firstUID: firstUID, secondUID: secondUID,
                         difference: difference, spread: spreads.max(),
                         correlation: detections.flatMap { $0 }.map(\.correlation).min())
    }
}
