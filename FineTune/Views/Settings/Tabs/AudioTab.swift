// FineTune/Views/Settings/Tabs/AudioTab.swift
import SwiftUI

@MainActor
struct AudioTab: View {
    @Bindable var settings: SettingsManager
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor

    /// Memoized sorted output devices for the system-sounds picker.
    @State private var sortedOutputDevices: [AudioDevice] = []

    private var unifiedLoudnessToggleBinding: Binding<Bool> {
        Binding(
            get: {
                settings.appSettings.loudnessCompensationEnabled
                    && settings.appSettings.loudnessEqualizationEnabled
            },
            set: { isEnabled in
                settings.appSettings.setUnifiedLoudnessEnabled(isEnabled)
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                outputDelaySection
                volumeSection
                devicesSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onAppear { updateSortedDevices() }
        .onChange(of: audioEngine.outputDevices) { _, _ in updateSortedDevices() }
        .onChange(of: settings.appSettings.lockInputDevice) { oldValue, newValue in
            if !oldValue && newValue {
                audioEngine.handleInputLockEnabled()
            }
        }
        .onChange(of: settings.appSettings.loudnessCompensationEnabled) { _, newValue in
            audioEngine.setLoudnessCompensationEnabled(newValue)
        }
        .onChange(of: settings.appSettings.loudnessEqualizationEnabled) { _, newValue in
            audioEngine.setLoudnessEqualizationEnabled(newValue)
        }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        SettingsSection("Volume") {
            SettingsRow(
                "Default Volume",
                description: "Initial volume for new apps"
            ) {
                VolumeSlider(
                    $settings.appSettings.defaultNewAppVolume,
                    range: 0.1...1.0,
                    width: 280
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Loudness Compensation",
                description: "Boost low frequencies at low volume"
            ) {
                Toggle("", isOn: unifiedLoudnessToggleBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection("Devices") {
            SettingsRow(
                "Lock Input Device",
                description: "Prevent auto-switching when devices connect"
            ) {
                Toggle("", isOn: $settings.appSettings.lockInputDevice)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            SettingsRowDivider()
            SettingsRow(
                "System Sounds",
                description: "Where alerts and effects play"
            ) {
                SystemSoundsDevicePicker(
                    devices: sortedOutputDevices,
                    deviceIconOverrides: audioEngine.settingsManager.deviceIconOverrides,
                    selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
                    defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
                    isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
                    onDeviceSelected: { deviceUID in
                        if let device = sortedOutputDevices.first(where: { $0.uid == deviceUID }) {
                            deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                        }
                    },
                    onSelectFollowDefault: {
                        deviceVolumeMonitor.setSystemFollowDefault()
                    }
                )
            }
            SettingsRowDivider()
            SettingsRow(
                "Alert Volume",
                description: "Volume for alerts and notifications"
            ) {
                VolumeSlider(
                    Binding(
                        get: { deviceVolumeMonitor.alertVolume },
                        set: { deviceVolumeMonitor.setAlertVolume($0) }
                    ),
                    range: 0...1,
                    width: 280
                )
            }
            .task {
                // No CoreAudio listener for alert volume — must poll via AppleScript.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    deviceVolumeMonitor.refreshAlertVolume()
                }
            }
        }
    }

    private var outputDelaySection: some View {
        SettingsSection("Output Synchronization") {
            SettingsRow("Manual Delay Compensation",
                        description: "Align your speakers with individual delays. Switching this mode briefly restarts playback.") {
                Toggle("", isOn: Binding(
                    get: { settings.outputDelayEnabled },
                    set: { value in Task { await audioEngine.setOutputDelayCompensationEnabled(value) } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(audioEngine.isUpdatingOutputDelay)
                .accessibilityLabel("Manual delay compensation")
            }
            if let error = audioEngine.outputDelayError {
                Text(error).font(.caption).foregroundStyle(.red).padding(12)
            }
            if settings.outputDelayEnabled {
                VStack(spacing: 8) {
                    ForEach(sortedOutputDevices) { device in
                        OutputDelayDeviceCard(device: device, milliseconds: delayBinding(for: device.uid))
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                        Text("Focus a number: ← → 1 ms · Shift 10 ms · Option 50 ms")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    Text("Keep your slowest output at 0 ms and delay the others. Select multiple outputs in the app's output picker. Values save automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(DesignTokens.Colors.recessedBackground)
            }
        }
    }

    private func delayBinding(for uid: String) -> Binding<Double> {
        Binding(get: { settings.outputDelayMilliseconds(for: uid) },
                set: { audioEngine.setOutputDelayMilliseconds($0, for: uid) })
    }

    private func updateSortedDevices() {
        sortedOutputDevices = audioEngine.prioritySortedOutputDevices
    }
}
