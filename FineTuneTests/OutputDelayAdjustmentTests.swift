import AppKit
import SwiftUI
import Testing
@testable import FineTune

@Suite("Output delay — fine adjustment")
@MainActor
struct OutputDelayAdjustmentTests {
    @Test("Step buttons apply exact offsets and clamp both endpoints")
    func steps() {
        #expect(OutputDelayAdjustment.value(232, adding: -50) == 182)
        #expect(OutputDelayAdjustment.value(232, adding: -10) == 222)
        #expect(OutputDelayAdjustment.value(232, adding: 10) == 242)
        #expect(OutputDelayAdjustment.value(232, adding: 50) == 282)
        #expect(OutputDelayAdjustment.value(5, adding: -10) == 0)
        #expect(OutputDelayAdjustment.value(1980, adding: 50) == 2000)
        #expect(OutputDelayAdjustment.value(232.49) == 232)
        #expect(OutputDelayAdjustment.value(.nan) == 0)
    }

    @Test("Arrows use 1/10/50 ms; Command, Control and unrelated keys keep native behavior")
    func shortcuts() {
        #expect(OutputDelayAdjustment.keyboardDelta(keyCode: 123, modifiers: []) == -1)
        #expect(OutputDelayAdjustment.keyboardDelta(keyCode: 124, modifiers: []) == 1)
        #expect(OutputDelayAdjustment.keyboardDelta(keyCode: 123, modifiers: .shift) == -10)
        #expect(OutputDelayAdjustment.keyboardDelta(keyCode: 124, modifiers: .option) == 50)
        #expect(OutputDelayAdjustment.keyboardDelta(keyCode: 124, modifiers: [.option, .shift]) == 50)
        #expect(OutputDelayAdjustment.keyboardDelta(keyCode: 124, modifiers: .command) == nil)
        #expect(OutputDelayAdjustment.keyboardDelta(keyCode: 123, modifiers: .control) == nil)
        #expect(OutputDelayAdjustment.keyboardDelta(keyCode: 36, modifiers: []) == nil)
    }

    private func event(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
    }

    @Test("An editing field adjusts the typed value, rather than moving the caret")
    func editingArrow() throws {
        var value = 200.0
        let parent = OutputDelayNumberField(value: Binding(get: { value }, set: { value = $0 }), deviceName: "Speaker")
        let coordinator = parent.makeCoordinator()
        let field = NSTextField()
        let editor = NSTextView()
        editor.string = "232"
        #expect(coordinator.handleArrow(try event(124), field: field, editor: editor))
        #expect(value == 233)
        #expect(editor.string == "233")
        #expect(field.stringValue == "233")
        #expect(coordinator.handleArrow(try event(123, modifiers: .shift), field: field, editor: editor))
        #expect(value == 223)
        #expect(coordinator.handleArrow(try event(124, modifiers: .option), field: field, editor: editor))
        #expect(value == 273)
    }

    @Test("Invalid drafts recover; out-of-range typed values stay within audio bounds")
    func invalidDraftAndBounds() throws {
        var value = 10.0
        let parent = OutputDelayNumberField(value: Binding(get: { value }, set: { value = $0 }), deviceName: "Speaker")
        let coordinator = parent.makeCoordinator()
        let field = NSTextField()
        let editor = NSTextView()
        editor.string = ""
        #expect(coordinator.handleArrow(try event(123, modifiers: .option), field: field, editor: editor))
        #expect(value == 0)
        editor.string = "1999"
        #expect(coordinator.handleArrow(try event(124, modifiers: .shift), field: field, editor: editor))
        #expect(value == 2000)
        field.stringValue = "invalid"
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        #expect(field.stringValue == "2000")
        field.stringValue = "-300"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(value == 0)
    }

    @Test("Non-adjustment shortcuts leave the numeric draft untouched")
    func editingCommands() throws {
        var value = 232.0
        let parent = OutputDelayNumberField(value: Binding(get: { value }, set: { value = $0 }), deviceName: "Speaker")
        let coordinator = parent.makeCoordinator()
        let field = NSTextField()
        let editor = NSTextView()
        editor.string = "232"
        #expect(!coordinator.handleArrow(try event(123, modifiers: .command), field: field, editor: editor))
        #expect(value == 232)
        #expect(editor.string == "232")
    }
}
