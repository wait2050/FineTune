import AudioToolbox
import Foundation
import Synchronization

/// One lock-free target per physical device, shared by its app renderers.
/// Only the delay target crosses threads; sample history belongs to one IOProc.
nonisolated final class OutputDelayControl: Sendable {
    static let maximumMilliseconds: Double = 2000
    private let target = Atomic<UInt64>(0)

    init(milliseconds: Double = 0) { setMilliseconds(milliseconds) }

    static func sanitize(_ milliseconds: Double) -> Double {
        milliseconds.isFinite ? min(max(milliseconds, 0), maximumMilliseconds) : 0
    }

    func setMilliseconds(_ milliseconds: Double) {
        target.store(Self.sanitize(milliseconds).bitPattern, ordering: .relaxed)
    }

    var milliseconds: Double {
        Double(bitPattern: target.load(ordering: .relaxed))
    }
}

/// Fixed-capacity, interleaved PCM history. Construct/destroy off the audio thread.
/// process/reset are single-writer, allocation-free, and work across buffer boundaries.
/// A delay edit crossfades two read heads over 10 ms instead of jumping the waveform.
nonisolated final class OutputDelayLine {
    let channelCount: Int
    private let sampleRate: Double
    private let capacity: Int
    private let history: UnsafeMutablePointer<Float>
    private let fadeFrames: Int
    private var writeFrame = 0
    private var validFrames = 0
    private var currentDelay: Int
    private var nextDelay: Int
    private var fadePosition = 0

    init(sampleRate: Double, channelCount: Int, milliseconds: Double) {
        precondition(sampleRate.isFinite && sampleRate > 0 && sampleRate <= 768_000)
        precondition(channelCount > 0)
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        capacity = Int(ceil(sampleRate * OutputDelayControl.maximumMilliseconds / 1000)) + 1
        history = .allocate(capacity: capacity * channelCount)
        history.initialize(repeating: 0, count: capacity * channelCount)
        fadeFrames = max(1, Int(sampleRate * 0.010))
        let initial = min(capacity - 1, Int((OutputDelayControl.sanitize(milliseconds) * sampleRate / 1000).rounded()))
        currentDelay = initial
        nextDelay = initial
    }

    deinit { history.deallocate() }

    /// Invalidate history without clearing megabytes in an audio callback.
    func reset(milliseconds: Double) {
        writeFrame = 0
        validFrames = 0
        currentDelay = min(capacity - 1, Int((OutputDelayControl.sanitize(milliseconds) * sampleRate / 1000).rounded()))
        nextDelay = currentDelay
        fadePosition = 0
    }

    func process(input: UnsafePointer<Float>?, output: UnsafeMutablePointer<Float>, frames: Int, milliseconds: Double) {
        let requested = min(capacity - 1, Int((OutputDelayControl.sanitize(milliseconds) * sampleRate / 1000).rounded()))
        // After reset, start at the requested delay (no fade from an empty history).
        if validFrames == 0 { currentDelay = requested; nextDelay = requested }
        for frame in 0..<frames {
            if currentDelay == nextDelay && requested != currentDelay {
                nextDelay = requested
                fadePosition = 0
            }
            let base = frame * channelCount
            let writeBase = writeFrame * channelCount
            for channel in 0..<channelCount {
                history[writeBase + channel] = input?[base + channel] ?? 0
            }
            validFrames = min(validFrames + 1, capacity)
            let oldIndex = ((writeFrame - currentDelay + capacity) % capacity) * channelCount
            let newIndex = ((writeFrame - nextDelay + capacity) % capacity) * channelCount
            let fading = currentDelay != nextDelay
            let mix = fading ? Float(fadePosition + 1) / Float(fadeFrames) : 0
            for channel in 0..<channelCount {
                let old = currentDelay < validFrames ? history[oldIndex + channel] : 0
                if fading {
                    let new = nextDelay < validFrames ? history[newIndex + channel] : 0
                    output[base + channel] = old + (new - old) * mix
                } else {
                    output[base + channel] = old
                }
            }
            if fading {
                fadePosition += 1
                if fadePosition >= fadeFrames { currentDelay = nextDelay; fadePosition = 0 }
            }
            writeFrame += 1
            if writeFrame == capacity { writeFrame = 0 }
        }
    }
}

/// Owned by the IOProc closure, including during secondary-tap crossfades and teardown.
/// Never swap/free this state underneath a running callback.
nonisolated final class OutputDelayBufferList: @unchecked Sendable {
    private let control: OutputDelayControl
    private let bufferList: UnsafeMutablePointer<AudioBufferList>
    private let data: [UnsafeMutablePointer<Float>]
    private let lines: [OutputDelayLine]
    private let maximumFrames = 65536

    convenience init(deviceID: AudioDeviceID, sampleRate: Double, control: OutputDelayControl) throws {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 768_000 else {
            throw NSError(domain: "OutputDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported delay sample rate."])
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard status == noErr, size >= MemoryLayout<AudioBufferList>.size else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot read delay input layout."])
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let configuration = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, configuration)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let buffers = UnsafeMutableAudioBufferListPointer(configuration)
        let channels = buffers.map { Int($0.mNumberChannels) }
        try self.init(channels: channels, sampleRate: sampleRate, control: control)
    }

    init(channels: [Int], sampleRate: Double, control: OutputDelayControl) throws {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 768_000 else {
            throw NSError(domain: "OutputDelay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported delay sample rate."])
        }
        guard !channels.isEmpty, channels.allSatisfy({ $0 > 0 && $0 <= 64 }) else {
            throw NSError(domain: "OutputDelay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported delay input layout."])
        }
        let historyFrames = Int(ceil(sampleRate * OutputDelayControl.maximumMilliseconds / 1000)) + 1
        let sampleBudget = 64 * 1024 * 1024 / MemoryLayout<Float>.size
        guard channels.reduce(0, +) <= sampleBudget / (historyFrames + maximumFrames) else {
            throw NSError(domain: "OutputDelay", code: 3, userInfo: [NSLocalizedDescriptionKey: "This device needs too much delay-buffer memory. Disable compensation for this route."])
        }
        self.control = control
        let scratchBytes = MemoryLayout<AudioBufferList>.size + (channels.count - 1) * MemoryLayout<AudioBuffer>.stride
        bufferList = UnsafeMutableRawPointer.allocate(byteCount: scratchBytes, alignment: MemoryLayout<AudioBufferList>.alignment)
            .bindMemory(to: AudioBufferList.self, capacity: 1)
        bufferList.pointee.mNumberBuffers = UInt32(channels.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        var delays: [OutputDelayLine] = []
        let scratch = UnsafeMutableAudioBufferListPointer(bufferList)
        for (index, count) in channels.enumerated() {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames * count)
            samples.initialize(repeating: 0, count: maximumFrames * count)
            storage.append(samples)
            delays.append(OutputDelayLine(sampleRate: sampleRate, channelCount: count, milliseconds: control.milliseconds))
            scratch[index] = AudioBuffer(mNumberChannels: UInt32(count), mDataByteSize: 0, mData: samples)
        }
        data = storage
        lines = delays
    }

    deinit {
        for pointer in data { pointer.deallocate() }
        bufferList.deallocate()
    }

    func reset() {
        let delay = control.milliseconds
        for line in lines { line.reset(milliseconds: delay) }
    }

    /// A changed layout must be recreated by the existing device-rate recovery path.
    /// Return nil (caller silences output), never overrun scratch or leak undelayed audio.
    func process(_ input: UnsafePointer<AudioBufferList>) -> UnsafePointer<AudioBufferList>? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count == lines.count else { reset(); return nil }
        let scratch = UnsafeMutableAudioBufferListPointer(bufferList)
        let delay = control.milliseconds
        for index in 0..<buffers.count {
            let buffer = buffers[index]
            let line = lines[index]
            // HAL may null disabled hardware-input streams. Preserve their metadata
            // and nil data instead of treating them as a live format change.
            if buffer.mData == nil {
                line.reset(milliseconds: delay)
                scratch[index] = buffer
                continue
            }
            scratch[index].mData = UnsafeMutableRawPointer(data[index])
            let bytesPerFrame = line.channelCount * MemoryLayout<Float>.size
            let frames = Int(buffer.mDataByteSize) / bytesPerFrame
            guard Int(buffer.mNumberChannels) == line.channelCount, frames <= maximumFrames,
                  Int(buffer.mDataByteSize) % bytesPerFrame == 0 else { reset(); return nil }
            line.process(input: buffer.mData?.assumingMemoryBound(to: Float.self), output: data[index], frames: frames, milliseconds: delay)
            scratch[index].mDataByteSize = buffer.mDataByteSize
        }
        return UnsafePointer(bufferList)
    }
}
