import AppKit
import AudioToolbox
import AVFoundation
import Synchronization

/// The same executable runs a small, isolated source process. The parent routes
/// that PID through normal ProcessTapControllers, so probes traverse the real
/// per-device aggregate/delay/gain path rather than a separate playback backend.
@MainActor
enum CalibrationSourceProcess {
    static var activePID: pid_t?
    static let argument = "--delay-calibration-source"

    static func runChild() -> Never {
        do {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: CalibrationProbe.sampleRate, channels: 2)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            silence.frameLength = silence.frameCapacity
            for channel in 0..<2 { silence.floatChannelData![channel].initialize(repeating: 0, count: Int(silence.frameLength)) }
            player.scheduleBuffer(silence, at: nil, options: .loops)
            try engine.start()
            player.play()
            while let line = readLine() {
                guard line.hasPrefix("play "), let tick = UInt64(line.dropFirst(5)) else { break }
                let values = CalibrationProbe.playback()
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
                buffer.frameLength = buffer.frameCapacity
                for channel in 0..<2 {
                    values.withUnsafeBufferPointer { source in
                        buffer.floatChannelData![channel].update(from: source.baseAddress!, count: values.count)
                    }
                }
                player.stop()
                player.scheduleBuffer(buffer)
                player.play(at: AVAudioTime(hostTime: tick))
            }
            player.stop()
            engine.stop()
            exit(0)
        } catch { exit(2) }
    }
}

/// Single writer (input tap), read only after stopping the engine. The tap does
/// no allocation, locking, logging, or file/network I/O. Samples live in RAM.
nonisolated final class CalibrationRecording: @unchecked Sendable {
    private let samples: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var written = 0
    private let published = Atomic<Int>(0)
    private let firstHostTime = Atomic<UInt64>(0)
    private let discontinuous = Atomic<Bool>(false)
    private var previousEnd: Double?
    let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        capacity = Int(sampleRate * 20)
        samples = .allocate(capacity: capacity)
    }
    deinit { samples.deallocate() }

    func append(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard time.isHostTimeValid, buffer.format.sampleRate == sampleRate,
              let channels = buffer.floatChannelData, buffer.format.channelCount > 0,
              !buffer.format.isInterleaved else {
            discontinuous.store(true, ordering: .relaxed)
            return
        }
        let start = AVAudioTime.seconds(forHostTime: time.hostTime)
        if let previousEnd, abs(start - previousEnd) > 0.025 {
            discontinuous.store(true, ordering: .relaxed)
        }
        previousEnd = start + Double(buffer.frameLength) / sampleRate
        if written == 0 { firstHostTime.store(time.hostTime, ordering: .relaxed) }
        let frames = min(Int(buffer.frameLength), capacity - written)
        // A single mic channel avoids phase cancellation from averaging arrays.
        samples.advanced(by: written).update(from: channels[0], count: frames)
        written += frames
        if frames != Int(buffer.frameLength) { discontinuous.store(true, ordering: .relaxed) }
        published.store(written, ordering: .releasing)
    }

    func snapshot() throws -> (samples: [Float], start: Double) {
        guard !discontinuous.load(ordering: .relaxed) else { throw CalibrationFailure.deviceChanged }
        let count = published.load(ordering: .acquiring)
        let tick = firstHostTime.load(ordering: .relaxed)
        guard count > 0, tick != 0 else { throw CalibrationFailure.noSignal }
        return (Array(UnsafeBufferPointer(start: samples, count: count)), AVAudioTime.seconds(forHostTime: tick))
    }
}

@MainActor
final class CalibrationMicrophone {
    private let engine = AVAudioEngine()
    private(set) var recording: CalibrationRecording?
    private var installed = false

    func start(device: AudioDevice) throws {
        guard !device.id.isBluetoothDevice() else { throw CalibrationFailure.inputUnavailable }
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CalibrationFailure.inputUnavailable }
        var id = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id)))
        guard status == noErr else { throw CalibrationFailure.inputUnavailable }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, (8_000...192_000).contains(format.sampleRate),
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
            throw CalibrationFailure.inputUnavailable
        }
        let recording = CalibrationRecording(sampleRate: format.sampleRate)
        self.recording = recording
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            recording.append(buffer, time: time)
        }
        installed = true
        try engine.start()
    }

    func stop() {
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
    }
}

@MainActor
final class CalibrationPlayback {
    private var process: Process?
    private var commands: FileHandle?
    private var taps: [ProcessTapController] = []

    func prepare(first: AudioDevice, second: AudioDevice, delays: [Double]) async throws {
        #if FINETUNE_TEST_HOST
        throw CalibrationFailure.sourceUnavailable
        #else
        guard let executable = Bundle.main.executableURL, CalibrationSourceProcess.activePID == nil else {
            throw CalibrationFailure.sourceUnavailable
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = [CalibrationSourceProcess.argument]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        commands = pipe.fileHandleForWriting
        CalibrationSourceProcess.activePID = process.processIdentifier
        var objects: [AudioObjectID] = []
        for _ in 0..<60 {
            try Task.checkCancellation()
            guard process.isRunning else { throw CalibrationFailure.sourceUnavailable }
            objects = ((try? AudioObjectID.readProcessList()) ?? []).filter {
                (try? $0.readProcessPID()) == process.processIdentifier && $0.readProcessIsRunning()
            }
            if !objects.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !objects.isEmpty else { throw CalibrationFailure.sourceUnavailable }
        let app = AudioApp(id: process.processIdentifier, processObjectIDs: objects,
                           name: "FineTune calibration", icon: NSImage(), bundleID: Bundle.main.bundleIdentifier)
        for (index, device) in [first, second].enumerated() {
            let tap = ProcessTapController(app: app, targetDeviceUIDs: [device.uid],
                                           outputDelayControl: OutputDelayControl(milliseconds: delays[index]))
            taps.append(tap) // Own partial activation too, so every error is cleaned up.
            tap.volume = 1
            try tap.activate()
        }
        // Bluetooth may take a moment to begin delivering its render callbacks.
        try await Task.sleep(for: .milliseconds(500))
        #endif
    }

    func play(acoustic: Bool) throws -> UInt64 {
        guard let process, process.isRunning, let commands, taps.count == 2 else { throw CalibrationFailure.sourceUnavailable }
        taps[0].isMuted = false
        taps[1].isMuted = acoustic
        let tick = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.6)
        try commands.write(contentsOf: Data("play \(tick)\n".utf8))
        return tick
    }

    func switchToSecond() {
        taps.first?.isMuted = true
        taps.last?.isMuted = false
    }

    func updateGains(_ gains: [Float]) {
        for (index, tap) in taps.enumerated() where index < gains.count {
            tap.volume = gains[index].isFinite ? min(1, max(0, gains[index])) : 0
        }
    }

    func stop() {
        try? commands?.write(contentsOf: Data("stop\n".utf8))
        try? commands?.close()
        commands = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        for tap in taps { tap.invalidate() }
        taps.removeAll()
        CalibrationSourceProcess.activePID = nil
    }
}
