import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("Delay calibration — Chinese panel layout")
@MainActor
struct DelayCalibrationRenderTests {
    @Test("Chinese calibration panel fits the existing settings width")
    func panelLayout() throws {
        let settings = SettingsManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let devices = MockAudioDeviceMonitor()
        devices.outputDevices = [
            AudioDevice(id: 1001, uid: "BuiltInSpeakerDevice", name: "Mac mini扬声器", icon: nil, supportsAutoEQ: false),
            AudioDevice(id: 1002, uid: "airpods", name: "AirPods Pro", icon: nil, supportsAutoEQ: true)
        ]
        let engine = AudioEngine(permission: AudioRecordingPermission(), settingsManager: settings,
                                 autoEQProfileManager: AutoEQProfileManager(), deviceProvider: devices,
                                 deviceVolumeMonitor: MockDeviceVolumeProviding(deviceMonitor: devices),
                                 startMonitorsAutomatically: false)
        let content = DelayCalibrationView(audioEngine: engine, settings: settings)
            .padding(16).frame(width: 680)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        #expect(size.width <= 680)
        #expect(size.height < 760)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try png.write(to: root.appendingPathComponent("build/DelayCalibrationUI.png"))
        window.contentView = nil
    }
}
