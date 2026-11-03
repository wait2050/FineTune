// FineTune/Views/Settings/Tabs/UpdatesTab.swift
import SwiftUI

@MainActor
struct UpdatesTab: View {
    @ObservedObject var updateManager: UpdateManager

    private var lastCheckDescription: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if let date = updateManager.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return L10n.format("Version %@ · %@", version, formatter.localizedString(for: date, relativeTo: .now))
        }
        return L10n.format("Version %@ · Never checked", version)
    }

    private var automaticallyChecksBinding: Binding<Bool> {
        Binding(
            get: { updateManager.automaticallyChecksForUpdates },
            set: { updateManager.automaticallyChecksForUpdates = $0 }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !updateManager.updatesSupported {
                    Text("This local delay edition is updated from its source project. Automatic updates from the official FineTune release are disabled.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Official source updates are prepared as pull requests in this fork. Install builds from your custom releases to keep Chinese UI and output delay controls.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("View custom releases", destination: URL(string: "https://github.com/wait2050/FineTune/releases")!)
                }
                SettingsSection("Software Updates") {
                    SettingsRow(
                        "Automatic updates",
                        description: "Check for new versions automatically"
                    ) {
                        Toggle("", isOn: automaticallyChecksBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    SettingsRowDivider()
                    SettingsRow(
                        "Last checked",
                        description: lastCheckDescription
                    ) {
                        Button("Check Now") {
                            updateManager.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .disabled(!updateManager.updatesSupported)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}
