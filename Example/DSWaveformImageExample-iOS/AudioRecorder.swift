import Foundation

/// SCAudioManager-backed `AudioRecording` implementation used by the iOS example apps.
/// Publishes `samples`, `recordingTime`, and `isRecording` so SwiftUI views in `Shared/` can drive
/// the live-recording UI without depending on the underlying Objective-C audio manager.
@MainActor
final class AudioRecorder: NSObject, ObservableObject, AudioRecording, RecordingDelegate {
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

    private func startRecording() {
        samples = []
        recordingTime = 0
        audioManager.startRecording()
    }

    private func stopRecording() {
        audioManager.stopRecording()
    }

    // MARK: - RecordingDelegate

    nonisolated func audioManager(_ manager: SCAudioManager!, didAllowRecording flag: Bool) {}

    nonisolated func audioManager(_ manager: SCAudioManager!, didFinishRecordingSuccessfully flag: Bool) {
        Task { @MainActor in
            isRecording = false
        }
    }

    nonisolated func audioManager(_ manager: SCAudioManager!, didUpdateRecordProgress progress: CGFloat) {
        let linear = Float(1 - pow(10, manager.lastAveragePower() / 20))
        let currentTime = manager.currentRecordingTime

        Task { @MainActor in
            recordingTime = currentTime
            // Append the same sample 3 times to speed up the animation — usually you'd add it once.
            samples += [linear, linear, linear]
        }
    }
}
