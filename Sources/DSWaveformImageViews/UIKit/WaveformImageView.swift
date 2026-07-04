#if os(iOS)
import Foundation
import AVFoundation
import UIKit
import DSWaveformImage

public class WaveformImageView: UIImageView {
    private let waveformImageDrawer: WaveformImageDrawer

    /// Identifies the most recent analysis request so stale completions can be ignored.
    private var currentGenerationID = UUID()

    /// The (url, size) the currently displayed / in-flight waveform was requested for.
    /// Used to avoid kicking off a fresh, expensive analysis on every `layoutSubviews`.
    private var renderedAudioURL: URL?
    private var renderedSize: CGSize = .zero

    public var configuration: Waveform.Configuration {
        didSet { updateWaveform() }
    }

    public var waveformAudioURL: URL? {
        didSet { updateWaveform() }
    }

    override public init(frame: CGRect) {
        configuration = Waveform.Configuration(size: frame.size)
        waveformImageDrawer = WaveformImageDrawer()
        super.init(frame: frame)
    }

    required public init?(coder aDecoder: NSCoder) {
        configuration = Waveform.Configuration()
        waveformImageDrawer = WaveformImageDrawer()
        super.init(coder: aDecoder)
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        updateWaveform()
    }

    /// Clears the audio data, emptying the waveform view.
    public func reset() {
        // Invalidate any in-flight analysis so its completion is ignored.
        currentGenerationID = UUID()
        renderedAudioURL = nil
        renderedSize = .zero
        waveformAudioURL = nil
        image = nil
    }
}

private extension WaveformImageView {
    func updateWaveform() {
        guard let audioURL = waveformAudioURL else {
            renderedAudioURL = nil
            renderedSize = .zero
            return
        }

        let targetSize = bounds.size
        // Skip zero-size layouts (nothing to draw) and non-finite bounds.
        guard targetSize.width > 0, targetSize.height > 0,
              targetSize.width.isFinite, targetSize.height.isFinite else {
            return
        }

        // Avoid re-running the (expensive) analysis when nothing relevant changed.
        // `layoutSubviews` can fire repeatedly (e.g. cell reuse / scrolling).
        if audioURL == renderedAudioURL, targetSize == renderedSize {
            return
        }

        renderedAudioURL = audioURL
        renderedSize = targetSize

        // Tag this request; only the newest one is allowed to update `image`.
        let generationID = UUID()
        currentGenerationID = generationID

        waveformImageDrawer.waveformImage(
            fromAudioAt: audioURL,
            with: configuration.with(size: targetSize),
            qos: .userInteractive
        ) { [weak self] image in
            DispatchQueue.main.async {
                guard let self = self, self.currentGenerationID == generationID else { return }
                self.image = image
            }
        }
    }
}
#endif
