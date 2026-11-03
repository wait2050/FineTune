// FineTune/Utilities/UpdateManager.swift
import Foundation
import Combine
import Sparkle

/// Manages app updates via Sparkle
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    let updatesSupported = !FineTuneRuntime.isDelayEdition && !FineTuneRuntime.isUnitTestHost
    @Published var canCheckForUpdates = false

    override init() {
        // Create the updater controller without auto-starting (prevents popup on launch)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        guard updatesSupported else { return }

        // Start updater to enable manual checks, but don't trigger auto-check UI
        try? updaterController.updater.start()

        // Observe when updates can be checked
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Check for updates manually
    func checkForUpdates() {
        guard updatesSupported else { return }
        updaterController.checkForUpdates(nil)
    }

    /// Whether automatic update checks are enabled
    var automaticallyChecksForUpdates: Bool {
        get { updatesSupported && updaterController.updater.automaticallyChecksForUpdates }
        set { if updatesSupported { updaterController.updater.automaticallyChecksForUpdates = newValue } }
    }

    /// Whether to automatically download updates
    var automaticallyDownloadsUpdates: Bool {
        get { updatesSupported && updaterController.updater.automaticallyDownloadsUpdates }
        set { if updatesSupported { updaterController.updater.automaticallyDownloadsUpdates = newValue } }
    }

    /// Last update check date
    var lastUpdateCheckDate: Date? {
        updaterController.updater.lastUpdateCheckDate
    }
}
