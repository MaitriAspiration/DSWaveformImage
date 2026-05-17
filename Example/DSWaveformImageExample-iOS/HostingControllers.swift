import SwiftUI
import UIKit

/// Hosts the shared SwiftUI gallery as the "Static Files" tab.
final class StaticFilesViewController: UIHostingController<WaveformGalleryView> {
    @MainActor @objc required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder, rootView: WaveformGalleryView())
    }
}

/// Hosts the shared SwiftUI live-recording showcase, wired to the iOS `AudioRecorder`.
final class LiveRecordingHostingController: UIHostingController<LiveRecordingShowcase<AudioRecorder>> {
    @MainActor @objc required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder, rootView: LiveRecordingShowcase(recorder: AudioRecorder()))
    }
}

/// Hosts the shared SwiftUI progress showcase.
final class ProgressHostingController: UIHostingController<ProgressShowcase> {
    @MainActor @objc required dynamic init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder, rootView: ProgressShowcase())
    }
}
