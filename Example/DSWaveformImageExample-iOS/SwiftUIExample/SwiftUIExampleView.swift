import DSWaveformImage
import DSWaveformImageViews
import SwiftUI

struct SwiftUIExampleView: View {
    private enum Tab: Hashable {
        case gallery
        case recorder
    }

    @State private var tab: Tab = .gallery

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                Label("Gallery", systemImage: "rectangle.grid.2x2").tag(Tab.gallery)
                Label("Live", systemImage: "mic.circle.fill").tag(Tab.recorder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 12)

            switch tab {
            case .gallery: WaveformGalleryView()
            case .recorder: LiveRecordingTab()
            }
        }
    }
}

private struct LiveRecordingTab: View {
    @StateObject private var audioRecorder = AudioRecorder()
    @State private var silence: Bool = true
    @State private var configuration: Waveform.Configuration = Waveform.Configuration(
        style: .striped(.init(color: .systemIndigo, width: 3, spacing: 3))
    )

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Live recording")
                    .font(.title2.weight(.semibold))
                Text("WaveformLiveCanvas streams microphone amplitude into a circular renderer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 16)

            WaveformLiveCanvas(
                samples: audioRecorder.samples,
                configuration: configuration,
                renderer: CircularWaveformRenderer(kind: .circle),
                shouldDrawSilencePadding: silence
            )
            .padding(.horizontal)

            Toggle("Pad silence", isOn: $silence)
                .controlSize(.mini)
                .padding(.horizontal)

            RecordingIndicatorView(
                samples: audioRecorder.samples,
                duration: audioRecorder.recordingTime,
                shouldDrawSilence: silence,
                isRecording: $audioRecorder.isRecording
            )
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
    }
}

struct SwiftUIExampleView_Previews: PreviewProvider {
    static var previews: some View {
        SwiftUIExampleView()
    }
}

private class AudioRecorder: NSObject, ObservableObject, RecordingDelegate {
    @Published var samples: [Float] = []
    @Published var recordingTime: TimeInterval = 0
    @Published var isRecording: Bool = false {
        didSet {
            guard oldValue != isRecording else { return }
            isRecording ? startRecording() : stopRecording()
        }
    }

    private let audioManager: SCAudioManager

    override init() {
        audioManager = SCAudioManager()
        super.init()
        audioManager.prepareAudioRecording()
        audioManager.recordingDelegate = self
    }

    func startRecording() {
        samples = []
        audioManager.startRecording()
        isRecording = true
    }

    func stopRecording() {
        audioManager.stopRecording()
        isRecording = false
    }

    // MARK: - RecordingDelegate

    func audioManager(_ manager: SCAudioManager!, didAllowRecording flag: Bool) {}
    func audioManager(_ manager: SCAudioManager!, didFinishRecordingSuccessfully flag: Bool) {}

    func audioManager(_ manager: SCAudioManager!, didUpdateRecordProgress progress: CGFloat) {
        let linear = 1 - pow(10, manager.lastAveragePower() / 20)
        // Here we add the same sample 3 times to speed up the animation.
        // Usually you'd just add the sample once.
        recordingTime = audioManager.currentRecordingTime
        samples += [linear, linear, linear]
    }
}
