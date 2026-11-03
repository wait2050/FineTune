import AppKit
import AudioToolbox
import Foundation
import Testing
@testable import FineTune

@Suite("Output delay — signal history")
struct OutputDelaySignalTests {
    private func render(_ input: [Float], line: OutputDelayLine, delay: Double) -> [Float] {
        var output = [Float](repeating: .nan, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                line.process(input: source.baseAddress, output: destination.baseAddress!,
                             frames: input.count / line.channelCount, milliseconds: delay)
            }
        }
        return output
    }

    @Test("Zero delay is bit-exact, including across ring wrap")
    func zeroDelay() {
        let line = OutputDelayLine(sampleRate: 1000, channelCount: 2, milliseconds: 0)
        let input = (0..<10000).map { Float($0 % 123) / 123 }
        #expect(render(input, line: line, delay: 0) == input)
    }

    @Test("Three device impulse offsets stay independent at 44.1/48/96 kHz")
    func independentOffsets() {
        for rate in [44100.0, 48000, 96000] {
            for milliseconds in [0.0, 80, 230] {
                let line = OutputDelayLine(sampleRate: rate, channelCount: 2, milliseconds: milliseconds)
                let delay = Int((milliseconds * rate / 1000).rounded())
                var input = [Float](repeating: 0, count: (delay + 700) * 2)
                input[0] = 0.75
                input[1] = -0.25
                var output: [Float] = []
                // Deliberately uneven IOProc sizes exercise block boundaries.
                for offset in stride(from: 0, to: input.count, by: 254) {
                    output += render(Array(input[offset..<min(offset + 254, input.count)]), line: line, delay: milliseconds)
                }
                #expect(output[delay * 2] == 0.75)
                #expect(output[delay * 2 + 1] == -0.25)
                #expect(output.filter { $0 != 0 }.count == 2)
            }
        }
    }

    @Test("Maximum delay survives repeated wraps and preserves channel order")
    func maximumDelay() {
        let line = OutputDelayLine(sampleRate: 1000, channelCount: 4, milliseconds: 2000)
        let input = (0..<24000).map { Float($0) / 24000 }
        let output = render(input, line: line, delay: 2000)
        #expect(output.prefix(8000).allSatisfy { $0 == 0 })
        #expect(Array(output.dropFirst(8000)) == Array(input.dropLast(8000)))
    }

    @Test("Reset discards all pre-mute history")
    func reset() {
        let line = OutputDelayLine(sampleRate: 1000, channelCount: 1, milliseconds: 200)
        _ = render([Float](repeating: 0.9, count: 500), line: line, delay: 200)
        line.reset(milliseconds: 200)
        #expect(render([Float](repeating: 0, count: 1000), line: line, delay: 200).allSatisfy { $0 == 0 })
    }

    @Test("Delay edits crossfade smoothly and converge to the requested offset")
    func edit() {
        let line = OutputDelayLine(sampleRate: 1000, channelCount: 1, milliseconds: 0)
        _ = render((0..<100).map(Float.init), line: line, delay: 0)
        let output = render((100..<150).map(Float.init), line: line, delay: 20)
        // A direct read-head jump would start at 80. The 10-frame crossfade starts at 98.
        #expect(abs(output[0] - 98) < 0.001)
        #expect(output[9] == 89)
        #expect(output[49] == 129)
        #expect(output.allSatisfy { $0.isFinite })
    }

    @Test("Invalid target values are clamped before they enter the audio thread")
    func bounds() {
        let control = OutputDelayControl(milliseconds: -.infinity)
        #expect(control.milliseconds == 0)
        for (value, expected) in [(Double.nan, 0.0), (-10, 0), (5000, 2000), (123.5, 123.5)] {
            control.setMilliseconds(value)
            #expect(control.milliseconds == expected)
        }
    }
}

@Suite("Output delay — backward-compatible settings")
@MainActor
struct OutputDelaySettingsTests {
    @Test("Old settings keep compensation off and all existing values")
    func migration() throws {
        let json = #"{"version":12,"appVolumes":{"music":0.5},"appSelectedDeviceUIDs":{"music":["speakers","headphones"]}}"#
        let settings = try JSONDecoder().decode(SettingsManager.Settings.self, from: Data(json.utf8))
        #expect(!settings.outputDelayEnabled)
        #expect(settings.outputDelaysMilliseconds.isEmpty)
        #expect(settings.appVolumes["music"] == 0.5)
        #expect(settings.appSelectedDeviceUIDs["music"] == ["speakers", "headphones"])
    }

    @Test("UID-keyed delays round trip and out-of-range persisted offsets are clamped")
    func roundTrip() throws {
        var original = SettingsManager.Settings()
        original.outputDelayEnabled = true
        original.outputDelaysMilliseconds = ["built-in": 220, "usb": 210, "bluetooth": 0, "bad": -10, "large": 3000]
        let restored = try JSONDecoder().decode(SettingsManager.Settings.self, from: JSONEncoder().encode(original))
        #expect(restored.outputDelayEnabled)
        #expect(restored.outputDelaysMilliseconds == ["built-in": 220, "usb": 210, "bluetooth": 0, "bad": 0, "large": 2000])
    }
}

@Suite("Output delay — routing and failure isolation")
@MainActor
struct OutputDelayRoutingTests {
    private let app = AudioApp(id: 91823, processObjectIDs: [], name: "Delay test", icon: NSImage(), bundleID: "test.delay")

    @Test("Disabled compensation delegates multi-output to exactly one original controller")
    func disabledRouting() async throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let registry = OutputDelayRegistry(settings: settings)
        var created: [RecordingProcessTapController] = []
        var delayControls: [OutputDelayControl?] = []
        let wrapper = OutputDelayTapController(app: app, targetDeviceUIDs: ["speaker", "bt"], sourceUID: nil,
                                              enabled: false, registry: registry) { uids, _, control in
            let child = RecordingProcessTapController(app: app, deviceUIDs: uids)
            created.append(child)
            delayControls.append(control)
            return child
        }
        try wrapper.activate(initial: TapInitialState())
        #expect(created.count == 1)
        #expect(created[0].currentDeviceUIDs == ["speaker", "bt"])
        #expect(delayControls[0] == nil)
        wrapper.volume = 0.42
        wrapper.isMuted = true
        #expect(created[0].volume == 0.42)
        #expect(created[0].isMuted)
        try await wrapper.updateDevices(to: ["usb"], preferredTapSourceDeviceUID: nil, sourceDeviceDead: false)
        #expect(created.count == 1)
        #expect(created[0].currentDeviceUIDs == ["usb"])
        wrapper.invalidate()
    }

    @Test("Enabled compensation gives each output its own live delay control; adding an output preserves history")
    func fanOut() async throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let registry = OutputDelayRegistry(settings: settings)
        registry.setMilliseconds(210, for: "speaker")
        registry.setMilliseconds(190, for: "usb")
        var created: [RecordingProcessTapController] = []
        var controls: [OutputDelayControl?] = []
        let wrapper = OutputDelayTapController(app: app, targetDeviceUIDs: ["speaker", "bt"], sourceUID: nil,
                                              enabled: true, registry: registry) { uids, _, control in
            let child = RecordingProcessTapController(app: app, deviceUIDs: uids)
            created.append(child)
            controls.append(control)
            return child
        }
        try wrapper.activate(initial: TapInitialState())
        #expect(created.map(\.currentDeviceUIDs) == [["speaker"], ["bt"]])
        #expect(controls[0]?.milliseconds == 210)
        #expect(controls[1]?.milliseconds == 0)
        registry.setMilliseconds(230, for: "speaker")
        #expect(controls[0]?.milliseconds == 230)
        #expect(controls[1]?.milliseconds == 0)
        try await wrapper.updateDevices(to: ["speaker", "usb", "bt"], preferredTapSourceDeviceUID: nil, sourceDeviceDead: false)
        #expect(created.count == 3)
        #expect(!created[0].events.contains(.invalidate))
        #expect(controls[2]?.milliseconds == 190)
        #expect(wrapper.currentDeviceUIDs == ["speaker", "usb", "bt"])
        wrapper.volume = 0.33
        wrapper.isMuted = true
        try await wrapper.setDelayEnabled(false)
        #expect(created.count == 4)
        #expect(created[3].currentDeviceUIDs == ["speaker", "usb", "bt"])
        #expect(controls[3] == nil)
        #expect(created[3].volume == 0.33)
        #expect(created[3].isMuted)
        wrapper.invalidate()
    }

    @Test("A failed mode toggle keeps the original route alive and cleans partially staged routes")
    func failedEnable() async throws {
        enum Failure: Error { case unavailable }
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var created: [RecordingProcessTapController] = []
        let wrapper = OutputDelayTapController(app: app, targetDeviceUIDs: ["speaker", "bt"], sourceUID: nil,
                                              enabled: false, registry: OutputDelayRegistry(settings: settings)) { uids, _, control in
            if uids == ["bt"] && control != nil { throw Failure.unavailable }
            let child = RecordingProcessTapController(app: app, deviceUIDs: uids)
            created.append(child)
            return child
        }
        try wrapper.activate(initial: TapInitialState())
        await #expect(throws: Failure.self) { try await wrapper.setDelayEnabled(true) }
        #expect(!created[0].events.contains(.invalidate))
        #expect(created[1].events.contains(.invalidate))
        #expect(wrapper.currentDeviceUIDs == ["speaker", "bt"])
        wrapper.invalidate()
    }
}

private final class DelayInputFixture {
    let pointer: UnsafeMutablePointer<AudioBufferList>
    private let samples: [UnsafeMutablePointer<Float>]

    init(channels: [Int], frames: Int) {
        let bytes = MemoryLayout<AudioBufferList>.size + (channels.count - 1) * MemoryLayout<AudioBuffer>.stride
        pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
            .bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.pointee.mNumberBuffers = UInt32(channels.count)
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        var allocated: [UnsafeMutablePointer<Float>] = []
        for (index, count) in channels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: frames * count)
            data.initialize(repeating: 0, count: frames * count)
            allocated.append(data)
            buffers[index] = AudioBuffer(mNumberChannels: UInt32(count), mDataByteSize: UInt32(frames * count * 4), mData: data)
        }
        samples = allocated
    }

    func write(_ values: [Float], at index: Int) {
        for (sample, value) in values.enumerated() { samples[index][sample] = value }
    }

    isolated deinit {
        for data in samples { data.deallocate() }
        pointer.deallocate()
    }
}

@Suite("Output delay — IOProc input layouts")
@MainActor
struct OutputDelayLayoutTests {
    @Test("Multiple input streams retain layout and are delayed independently")
    func multipleStreams() throws {
        let control = OutputDelayControl(milliseconds: 2)
        let delay = try OutputDelayBufferList(channels: [1, 2], sampleRate: 1000, control: control)
        let input = DelayInputFixture(channels: [1, 2], frames: 4)
        input.write([1, 2, 3, 4], at: 0)
        input.write([10, -10, 20, -20, 30, -30, 40, -40], at: 1)
        let pointer = try #require(delay.process(input.pointer))
        let output = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: pointer))
        #expect(output.count == 2)
        #expect(output[0].mNumberChannels == 1)
        #expect(output[1].mNumberChannels == 2)
        let mono = output[0].mData!.assumingMemoryBound(to: Float.self)
        let stereo = output[1].mData!.assumingMemoryBound(to: Float.self)
        #expect(Array(UnsafeBufferPointer(start: mono, count: 4)) == [0, 0, 1, 2])
        #expect(Array(UnsafeBufferPointer(start: stereo, count: 8)) == [0, 0, 0, 0, 10, -10, 20, -20])
        // The CoreAudio-owned source must stay untouched.
        let source = UnsafeMutableAudioBufferListPointer(input.pointer)[1].mData!.assumingMemoryBound(to: Float.self)
        #expect(source[0] == 10)
    }

    @Test("Changed callback layout fails safely and clears old history")
    func changedLayout() throws {
        let delay = try OutputDelayBufferList(channels: [2], sampleRate: 1000, control: OutputDelayControl(milliseconds: 1))
        let good = DelayInputFixture(channels: [2], frames: 4)
        good.write([1, 1, 1, 1, 1, 1, 1, 1], at: 0)
        #expect(delay.process(good.pointer) != nil)
        let wrong = DelayInputFixture(channels: [1], frames: 4)
        #expect(delay.process(wrong.pointer) == nil)
        good.write([Float](repeating: 0, count: 8), at: 0)
        let pointer = try #require(delay.process(good.pointer))
        let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: pointer))[0]
        let data = buffer.mData!.assumingMemoryBound(to: Float.self)
        #expect(Array(UnsafeBufferPointer(start: data, count: 8)).allSatisfy { $0 == 0 })
    }

    @Test("Invalid rates and excessive layouts are rejected before activation")
    func invalidConfiguration() {
        #expect(throws: (any Error).self) {
            try OutputDelayBufferList(channels: [2], sampleRate: .nan, control: OutputDelayControl())
        }
        #expect(throws: (any Error).self) {
            try OutputDelayBufferList(channels: [64], sampleRate: 768000, control: OutputDelayControl())
        }
    }
}

extension OutputDelayLayoutTests {
    @Test("Disabled hardware-input streams stay nil while the tap stream is delayed")
    func disabledHardwareInput() throws {
        let delay = try OutputDelayBufferList(channels: [1, 2], sampleRate: 1000, control: OutputDelayControl(milliseconds: 1))
        let input = DelayInputFixture(channels: [1, 2], frames: 2)
        let buffers = UnsafeMutableAudioBufferListPointer(input.pointer)
        buffers[0] = AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        input.write([0.5, -0.5, 0.25, -0.25], at: 1)
        let result = try #require(delay.process(input.pointer))
        let output = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: result))
        #expect(output[0].mData == nil)
        let data = output[1].mData!.assumingMemoryBound(to: Float.self)
        #expect(Array(UnsafeBufferPointer(start: data, count: 4)) == [0, 0, 0.5, -0.5])
    }
}

extension OutputDelayRoutingTests {
    @Test("Invalidating queued work never recreates an app's routes")
    func invalidatedWhileQueued() async throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var creations = 0
        let wrapper = OutputDelayTapController(app: app, targetDeviceUIDs: ["speaker", "bt"], sourceUID: nil,
                                              enabled: false, registry: OutputDelayRegistry(settings: settings)) { uids, _, _ in
            creations += 1
            return RecordingProcessTapController(app: app, deviceUIDs: uids)
        }
        try wrapper.activate(initial: TapInitialState())
        let transition = Task { try await wrapper.setDelayEnabled(true) }
        wrapper.invalidate()
        await #expect(throws: CancellationError.self) { try await transition.value }
        #expect(wrapper.currentDeviceUIDs.isEmpty)
        #expect(creations == 1)
    }
}
