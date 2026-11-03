import Foundation

/// Localize runtime strings at display boundaries; identifiers and saved values
/// stay in their original form so upstream settings and routing remain compatible.
nonisolated enum L10n {
    static func string(_ key: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func routingSubtitle(_ source: String) -> String {
        guard source.hasPrefix("Multi · ") else { return string(source) }
        let detail = String(source.dropFirst("Multi · ".count))
        if detail.hasSuffix(" devices"), let count = Int(detail.dropLast(" devices".count)) {
            return string("Multi") + " · " + format("%lld devices", count)
        }
        return string("Multi") + " · " + detail
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: Locale.current, arguments: arguments)
    }
}
