import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("Output delay — device card layout")
@MainActor
struct OutputDelayCardRenderTests {
    @Test("Device cards fit the settings content width in light and dark appearances")
    func renderCards() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build")
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            let content = VStack(spacing: 8) {
                OutputDelayDeviceCard(device: AudioDevice(id: 1, uid: "built-in", name: "Mac mini扬声器", icon: NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil), supportsAutoEQ: false), milliseconds: .constant(232))
                OutputDelayDeviceCard(device: AudioDevice(id: 2, uid: "monitor", name: "Mi Monitor", icon: NSImage(systemSymbolName: "display", accessibilityDescription: nil), supportsAutoEQ: false), milliseconds: .constant(0))
                OutputDelayDeviceCard(device: AudioDevice(id: 3, uid: "headphones", name: "AirPods Pro", icon: NSImage(systemSymbolName: "airpodspro", accessibilityDescription: nil), supportsAutoEQ: true), milliseconds: .constant(180))
            }
            .padding(12)
            .frame(width: 648)
            .background(DesignTokens.Colors.recessedBackground)
            .environment(\.colorScheme, scheme)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 648, height: 340)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 648, height: 340), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= 648)
            #expect(host.fittingSize.height <= 340)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("OutputDelayUI-\(name).png"))
            window.contentView = nil
        }
    }
}
