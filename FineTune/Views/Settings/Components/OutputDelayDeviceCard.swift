import AppKit
import SwiftUI

/// Shared adjustment rules for buttons, typed values and keyboard input.
nonisolated enum OutputDelayAdjustment {
    static func value(_ value: Double, adding delta: Double = 0) -> Double {
        OutputDelayControl.sanitize(value + delta).rounded()
    }

    static func keyboardDelta(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Double? {
        guard !modifiers.contains(.command), !modifiers.contains(.control),
              keyCode == 123 || keyCode == 124 else { return nil }
        let step: Double = modifiers.contains(.option) ? 50 : (modifiers.contains(.shift) ? 10 : 1)
        return keyCode == 123 ? -step : step
    }
}

/// NSTextField's field editor normally consumes arrow keys for caret movement.
/// Handle them in its delegate so the shortcuts also work while editing a number.
@MainActor
struct OutputDelayNumberField: NSViewRepresentable {
    @Binding var value: Double
    let deviceName: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        field.alignment = .right
        field.focusRingType = .exterior
        field.stringValue = Self.text(value)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Delay in milliseconds for \(deviceName)")
        field.setAccessibilityHelp("Left and right arrows: 1 millisecond. Shift: 10. Option: 50.")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let canonical = OutputDelayAdjustment.value(value)
        if field.currentEditor() == nil || canonical != context.coordinator.lastPublishedValue {
            context.coordinator.show(canonical, in: field)
        }
    }

    private static func text(_ value: Double) -> String { String(Int(OutputDelayAdjustment.value(value))) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OutputDelayNumberField
        private(set) var lastPublishedValue: Double

        init(_ parent: OutputDelayNumberField) {
            self.parent = parent
            lastPublishedValue = OutputDelayAdjustment.value(parent.value)
        }

        func show(_ value: Double, in field: NSTextField) {
            lastPublishedValue = OutputDelayAdjustment.value(value)
            let text = OutputDelayNumberField.text(lastPublishedValue)
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.string = text
                editor.selectedRange = NSRange(location: text.utf16.count, length: 0)
            }
        }

        private func publish(_ value: Double) {
            lastPublishedValue = OutputDelayAdjustment.value(value)
            parent.value = lastPublishedValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let number = Double(field.stringValue), number.isFinite else { return }
            // Preserve partially typed text/caret until Return or focus leaves the field.
            publish(number)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            publish(Double(field.stringValue) ?? parent.value)
            show(parent.value, in: field)
        }

        @discardableResult
        func handleArrow(_ event: NSEvent, field: NSTextField, editor: NSTextView) -> Bool {
            guard let delta = OutputDelayAdjustment.keyboardDelta(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
            let base = Double(editor.string).flatMap { $0.isFinite ? $0 : nil } ?? parent.value
            publish(OutputDelayAdjustment.value(base, adding: delta))
            let text = OutputDelayNumberField.text(parent.value)
            field.stringValue = text
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let field = control as? NSTextField, let event = NSApp.currentEvent,
                  event.type == .keyDown else { return false }
            return handleArrow(event, field: field, editor: textView)
        }
    }
}

@MainActor
struct OutputDelayDeviceCard: View {
    let device: AudioDevice
    @Binding var milliseconds: Double

    private var displayedValue: Int { Int(OutputDelayAdjustment.value(milliseconds)) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if let icon = device.icon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 16))
                    }
                }
                .frame(width: 32, height: 32)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .help(device.name)
                    Text(displayedValue == 0 ? "No added delay" : "Added delay")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                OutputDelayNumberField(value: $milliseconds, deviceName: device.name)
                    .frame(width: 78, height: 30)
                Text("ms")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Reset") { milliseconds = 0 }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .fixedSize()
                    .disabled(displayedValue == 0)
                    .accessibilityLabel("Reset delay for \(device.name)")
            }

            HStack(spacing: 14) {
                // A continuous native slider avoids rendering 2001 tick marks as a
                // black stripe. Round its binding instead to keep integer-ms precision.
                Slider(value: Binding(
                    get: { milliseconds },
                    set: { milliseconds = OutputDelayAdjustment.value($0) }
                ), in: 0...OutputDelayControl.maximumMilliseconds)
                .accessibilityLabel("Delay for \(device.name)")
                .accessibilityValue("\(displayedValue) milliseconds")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjust(1)
                    case .decrement: adjust(-1)
                    @unknown default: break
                    }
                }

                HStack(spacing: 5) {
                    stepButton(-50)
                    stepButton(-10)
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 16).padding(.horizontal, 3)
                    stepButton(10)
                    stepButton(50)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.5)
        }
    }

    private func stepButton(_ delta: Int) -> some View {
        Button(delta > 0 ? "+\(delta)" : "−\(-delta)") { adjust(Double(delta)) }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .frame(minWidth: 44)
            .fixedSize()
            .buttonRepeatBehavior(.enabled)
            .disabled(delta < 0 ? displayedValue == 0 : displayedValue == 2000)
            .help("\(delta > 0 ? "Increase" : "Decrease") delay by \(abs(delta)) ms")
            .accessibilityLabel("\(delta > 0 ? "Increase" : "Decrease") delay by \(abs(delta)) milliseconds for \(device.name)")
    }

    private func adjust(_ delta: Double) {
        milliseconds = OutputDelayAdjustment.value(milliseconds, adding: delta)
    }
}
