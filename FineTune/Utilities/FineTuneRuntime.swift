import AppKit
import Foundation

/// Keep the downloadable local edition and hosted unit tests separate from the
/// user's installed FineTune. Ordinary upstream builds retain their identifiers.
nonisolated enum FineTuneRuntime {
    static var isUnitTestHost: Bool {
        #if FINETUNE_TEST_HOST
        true
        #else
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #endif
    }

    static var isDelayEdition: Bool {
        Bundle.main.bundleIdentifier == "com.finetuneapp.FineTune.Delay"
    }

    static var aggregateNamePrefix: String { isDelayEdition ? "FineTuneDelay-" : "FineTune-" }

    static var defaultSettingsDirectory: URL {
        if isUnitTestHost {
            return FileManager.default.temporaryDirectory.appendingPathComponent("FineTuneTestHost-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(isDelayEdition ? "FineTune Delay" : "FineTune")
    }
}
