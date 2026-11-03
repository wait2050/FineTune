import Foundation
import Testing
@testable import FineTune

@Suite("Calibration — independent test volumes")
@MainActor
struct CalibrationTestVolumeTests {
    @Test("Old settings retain their music volumes and begin at the original test loudness")
    func oldSettings() throws {
        let data = Data(#"{"version":13,"appVolumes":{"music":0.4},"outputDelaysMilliseconds":{"speaker":230}}"#.utf8)
        let restored = try JSONDecoder().decode(SettingsManager.Settings.self, from: data)
        #expect(restored.calibrationTestLevels.isEmpty)
        #expect(restored.appVolumes["music"] == 0.4)
        #expect(restored.outputDelaysMilliseconds["speaker"] == 230)
        #expect(abs(0.8 * CalibrationTestLevel.defaultValue - 0.16) < 0.0001)
    }

    @Test("Each device remembers a separate test level across settings serialization")
    func persistence() throws {
        var original = SettingsManager.Settings()
        original.calibrationTestLevels = ["speaker": 0.2, "airpods": 0.85, "quiet": -1, "loud": 5]
        let decoded = try JSONDecoder().decode(SettingsManager.Settings.self, from: JSONEncoder().encode(original))
        #expect(decoded.calibrationTestLevels == ["speaker": 0.2, "airpods": 0.85, "quiet": 0.1, "loud": 1])
    }

    @Test("Raising AirPods test volume preserves speaker, music and delay settings")
    func independentLevels() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = SettingsManager(directory: directory)
        settings.setVolume(for: "music", to: 0.4)
        settings.setOutputDelayMilliseconds(230, for: "speaker")
        settings.setCalibrationTestLevel(0.9, for: "airpods")
        #expect(settings.calibrationTestLevel(for: "airpods") == 0.9)
        #expect(settings.calibrationTestLevel(for: "speaker") == 0.2)
        #expect(settings.outputDelayMilliseconds(for: "speaker") == 230)
        #expect(settings.getVolume(for: "music") == 0.4)
    }

    @Test("Loudness has five times the previous headroom and still obeys device attenuation and mute")
    func headroomAndMute() {
        let normal = CalibrationTestLevel.gain(level: 0.2, deviceGain: 0.7, muted: false)
        let louder = CalibrationTestLevel.gain(level: 1, deviceGain: 0.7, muted: false)
        #expect(abs(louder / normal - 5) < 0.001)
        #expect(CalibrationTestLevel.gain(level: 1, deviceGain: 0.7, muted: true) == 0)
        #expect(CalibrationTestLevel.gain(level: .nan, deviceGain: 1, muted: false) == 0.2)
        #expect(CalibrationTestLevel.gain(level: 1, deviceGain: .infinity, muted: false) == 0)
        #expect(CalibrationTestLevel.gain(level: 5, deviceGain: 4, muted: false) == 1)
    }
}
