import SwiftUI

@MainActor
struct DelayCalibrationView: View {
    let audioEngine: AudioEngine
    let settings: SettingsManager
    @State private var model = DelayCalibrationModel()
    @State private var firstUID = ""
    @State private var secondUID = ""
    @State private var microphoneUID = ""
    @State private var applied = false
    @State private var previous: (first: String, second: String, delays: [Double], enabled: Bool)?

    private var outputs: [AudioDevice] { audioEngine.prioritySortedOutputDevices }
    private var microphones: [AudioDevice] { DelayCalibrationModel.usableMicrophones(audioEngine.inputDevices) }
    private var first: AudioDevice? { outputs.first { $0.uid == firstUID } }
    private var second: AudioDevice? { outputs.first { $0.uid == secondUID } }
    private var microphone: AudioDevice? { microphones.first { $0.uid == microphoneUID } }
    private var validPair: Bool { first != nil && second != nil && firstUID != secondUID }
    private var selectionKey: String { firstUID + "|" + secondUID + "|" + microphoneUID }

    var body: some View {
        SettingsSection("Delay test & calibration") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tint)
                        .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bring your outputs into sync").font(.system(size: 14, weight: .semibold))
                        Text("Test your current delays, or use a wired microphone to measure both outputs. Nothing changes until you apply a result.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 14) {
                    devicePicker("First output", selection: $firstUID, devices: outputs)
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary).padding(.top, 15)
                    devicePicker("Second output", selection: $secondUID, devices: outputs)
                }
                .disabled(model.isRunning || audioEngine.isUpdatingOutputDelay)

                HStack(spacing: 8) {
                    Button { start(acoustic: false) } label: {
                        Label("Play sync test", systemImage: "play.fill")
                    }
                    .disabled(!validPair || model.isRunning || audioEngine.isUpdatingOutputDelay)
                    Button("Read device estimate") {
                        if let first, let second { applied = false; model.estimate(first: first, second: second) }
                    }.disabled(!validPair || model.isRunning)
                    Spacer(minLength: 0)
                    if model.isRunning { Button("Stop", role: .cancel) { model.cancel() } }
                }
                if previous != nil {
                    Button("Undo calibration") { Task { await undo() } }
                        .disabled(model.isRunning || audioEngine.isUpdatingOutputDelay)
                }
                Text("Test sounds use your current compensation. Pause music first and keep headphone volume comfortable.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                devicePicker("Measurement microphone", selection: $microphoneUID, devices: microphones)
                    .disabled(model.isRunning)
                Text("Use a wired headset mic or USB microphone. Hold the AirPods sound outlet near it so it can hear both outputs; keep the mic still. Bluetooth microphones are excluded to avoid changing playback mode.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if microphones.isEmpty {
                    Label("Connect a wired or USB microphone for automatic calibration.", systemImage: "mic.slash")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
                HStack {
                    Button { start(acoustic: true) } label: {
                        Label("Start automatic calibration", systemImage: "mic.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!validPair || microphone == nil || model.isRunning || audioEngine.isUpdatingOutputDelay)
                    Text("About 16 seconds · 3 measurements per output")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("The microphone is used only during calibration. Recordings stay in memory and are discarded afterward.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if model.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(LocalizedStringKey(model.phase)).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(model.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().font(.caption)
                        }
                        ProgressView(value: model.progress)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                }
                if let result = model.result, validPair, result.firstUID == firstUID, result.secondUID == secondUID {
                    resultCard(result)
                }
            }
            .padding(16)
        }
        .onAppear { chooseDefaults() }
        .onDisappear { model.cancel() }
        .onChange(of: selectionKey) { _, _ in model.clear(); applied = false }
        .onChange(of: outputs) { _, _ in
            if !validPair { model.clear(); applied = false; chooseDefaults() }
        }
        .onChange(of: audioEngine.inputDevices) { _, _ in
            if microphone == nil { model.clear(); chooseDefaults() }
        }
    }

    private func devicePicker(_ title: LocalizedStringKey, selection: Binding<String>, devices: [AudioDevice]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                Text("Select a device").tag("")
                ForEach(devices) { device in Text(device.name).tag(device.uid) }
            }
            .labelsHidden().frame(maxWidth: .infinity).accessibilityLabel(Text(title))
        }
    }

    private func resultCard(_ result: DelayCalibrationResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(result.method == .acoustic ? "Measured compensation" : "Driver estimate · verify by ear"),
                  systemImage: result.method == .acoustic ? "checkmark.waveform" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 24) {
                resultValue(first?.name ?? "", milliseconds: result.firstMilliseconds)
                resultValue(second?.name ?? "", milliseconds: result.secondMilliseconds)
            }
            if let spread = result.spreadMilliseconds {
                Text(L10n.format("Repeat spread: %.1f ms · 3 measurements per output", spread))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("Driver estimates may omit Bluetooth buffering. They are a starting point, not a measured result.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button(LocalizedStringKey(applied ? "Compensation applied" : "Apply compensation")) { Task { await apply(result) } }
                    .disabled(applied || model.isRunning || audioEngine.isUpdatingOutputDelay)
                Spacer(minLength: 0)
            }
            Text("Select both devices in each app's output picker to play through them together. Recheck after reconnecting Bluetooth.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resultValue(_ name: String, milliseconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 11)).lineLimit(1)
            Text("\(Int(milliseconds)) ms").font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseDefaults() {
        if first == nil { firstUID = outputs.first(where: { $0.uid == "BuiltInSpeakerDevice" })?.uid ?? outputs.first?.uid ?? "" }
        if second == nil || secondUID == firstUID {
            secondUID = outputs.first(where: { $0.uid != firstUID && $0.id.isBluetoothDevice() })?.uid
                ?? outputs.first(where: { $0.uid != firstUID })?.uid ?? ""
        }
        if microphone == nil { microphoneUID = microphones.first?.uid ?? "" }
    }

    private func start(acoustic: Bool) {
        guard let first, let second else { return }
        if acoustic { applied = false }
        model.start(first: first, second: second, microphone: microphone, acoustic: acoustic,
                    currentDelays: [first, second].map { settings.outputDelayEnabled ? settings.outputDelayMilliseconds(for: $0.uid) : 0 },
                    captureAuthorized: audioEngine.permission.status == .authorized,
                    outputGains: {
                        [first, second].map { device in
                            if audioEngine.deviceVolumeMonitor.muteStates[device.id] ?? false { return 0 }
                            return audioEngine.deviceVolumeMonitor.outputProcessingGain(for: device.id)
                        }
                    })
    }

    private func apply(_ result: DelayCalibrationResult) async {
        guard validPair, !applied, !model.isRunning, !audioEngine.isUpdatingOutputDelay,
              result.firstUID == firstUID, result.secondUID == secondUID else { return }
        do {
            guard let first, let second else { throw CalibrationFailure.deviceChanged }
            try model.validateResult(first: first, second: second)
        } catch { model.error = error.localizedDescription; return }
        let saved = (first: firstUID, second: secondUID,
                     delays: [settings.outputDelayMilliseconds(for: firstUID), settings.outputDelayMilliseconds(for: secondUID)],
                     enabled: settings.outputDelayEnabled)
        await audioEngine.setOutputDelayCompensationEnabled(true)
        guard settings.outputDelayEnabled else { model.error = audioEngine.outputDelayError; return }
        audioEngine.setOutputDelayMilliseconds(result.firstMilliseconds, for: result.firstUID)
        audioEngine.setOutputDelayMilliseconds(result.secondMilliseconds, for: result.secondUID)
        previous = saved
        applied = true
    }

    private func undo() async {
        guard let previous else { return }
        audioEngine.setOutputDelayMilliseconds(previous.delays[0], for: previous.first)
        audioEngine.setOutputDelayMilliseconds(previous.delays[1], for: previous.second)
        await audioEngine.setOutputDelayCompensationEnabled(previous.enabled)
        applied = false
        self.previous = nil
    }
}
