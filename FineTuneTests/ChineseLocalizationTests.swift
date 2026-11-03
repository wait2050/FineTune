import Foundation
import Testing
@testable import FineTune

@Suite("Simplified Chinese localization")
struct ChineseLocalizationTests {
    private func chineseBundle() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test("Compiled Chinese resources contain the main interface and delay controls")
    func compiledStrings() throws {
        let bundle = try chineseBundle()
        for (key, expected) in [
            ("General", "通用"), ("Audio", "音频"), ("Settings", "设置"),
            ("Output Synchronization", "多设备声音同步"),
            ("Manual Delay Compensation", "手动延迟补偿"),
            ("Added delay", "附加延迟"), ("No added delay", "不附加延迟"),
            ("Reset", "重置"), ("Equalizer", "均衡器"), ("Single", "单设备"), ("Multi", "多设备")
        ] {
            #expect(L10n.string(key, bundle: bundle) == expected)
        }
    }

    @Test("English fallback remains available alongside Chinese")
    func englishFallback() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(L10n.string("General", bundle: bundle) == "General")
        #expect(L10n.string("Manual Delay Compensation", bundle: bundle) == "Manual Delay Compensation")
    }

    @Test("Dynamic device labels preserve Unicode names and format arguments")
    func formattedLabels() throws {
        let bundle = try chineseBundle()
        let format = L10n.string("Delay in milliseconds for %@", bundle: bundle)
        let label = String(format: format, "客厅音箱")
        #expect(label == "客厅音箱的延迟，单位毫秒")
        let devices = String(format: L10n.string("%lld devices", bundle: bundle), 3)
        #expect(devices == "3 台设备")
        #expect(L10n.string("My Custom Profile", bundle: bundle) == "My Custom Profile")
    }

    @Test("System permission messages have Chinese InfoPlist translations")
    func permissionMessages() throws {
        let bundle = try chineseBundle()
        let message = bundle.localizedString(forKey: "NSAudioCaptureUsageDescription", value: nil, table: "InfoPlist")
        #expect(message.contains("系统音频"))
        #expect(message.contains("FineTune"))
    }

    @Test("The catalog preserves printf arguments for every translation")
    func catalogArguments() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("FineTune/Resources/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        let regex = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ll|l)?[@diuofsg]"#)
        func arguments(_ text: String) -> [String] {
            let clean = text.replacingOccurrences(of: "%%", with: "")
            return regex.matches(in: clean, range: NSRange(clean.startIndex..., in: clean))
                .compactMap { Range($0.range, in: clean).map { String(clean[$0]) } }.sorted()
        }
        for (key, entry) in strings {
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
            let unit = try #require(chinese["stringUnit"] as? [String: String])
            let translated = try #require(unit["value"])
            #expect(unit["state"] == "translated")
            #expect(arguments(key) == arguments(translated), "Placeholder mismatch: \(key)")
        }
    }
}
