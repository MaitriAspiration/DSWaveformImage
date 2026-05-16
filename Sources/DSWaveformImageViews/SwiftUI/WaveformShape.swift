import Foundation
import SwiftUI
import DSWaveformImage

/// A waveform SwiftUI `Shape` object for generating a shape path from component(s) of the waveform.
/// **Note:** The Shape does *not* style itself. Use `WaveformView` for that purpose and only use the Shape directly if needed.
///
/// If `renderer` is a `ChannelAwareWaveformRenderer` with a non-`.merged` selection, the caller is
/// responsible for providing `samples` in the matching layout (e.g. `[allLeft..., allRight...]` for
/// `.stereo`). The Shape only renders; it cannot re-sample the audio. `WaveformView` handles this
/// automatically — prefer it when working from an `audioURL`.
@available(iOS 15.0, macOS 12.0, *)
public struct WaveformShape: Shape {
    private let samples: [Float]
    private let configuration: Waveform.Configuration
    private let renderer: WaveformRenderer

    public init(
        samples: [Float],
        configuration: Waveform.Configuration = Waveform.Configuration(),
        renderer: WaveformRenderer = LinearWaveformRenderer()
    ) {
        self.samples = samples
        self.configuration = configuration
        self.renderer = renderer
    }

    public func path(in rect: CGRect) -> Path {
        // Debug-only sanity check: stereo expects an even-length sample array (one half per channel).
        // We can't verify content correctness here — that's on the caller — but an odd count is
        // unambiguously wrong and easy to catch.
        if let channelAware = renderer as? ChannelAwareWaveformRenderer, channelAware.channelSelection == .stereo {
            assert(samples.count % 2 == 0, "WaveformShape: a `.stereo` renderer expects samples laid out as [allLeft..., allRight...] (even length). Got \(samples.count).")
        }

        let size = CGSize(width: rect.maxX, height: rect.maxY)
        let dampedSamples = configuration.shouldDamp ? damp(samples, with: configuration) : samples
        let path = renderer.path(samples: dampedSamples, with: configuration.with(size: size), lastOffset: 0)

        return Path(path)
    }

    /// Whether the shape has no underlying samples to display.
    var isEmpty: Bool {
        samples.isEmpty
    }

    /// SwiftUI fill style this shape's path expects. Uses even-odd when the renderer's path is
    /// built from multiple subpaths that need region subtraction (e.g. `CircularWaveformRenderer`
    /// in `.ring` kind). Defaults to non-zero for everyone else.
    public var fillStyle: FillStyle {
        let eoFill = (renderer as? CircularWaveformRenderer)?.prefersEvenOddFillRule ?? false
        return FillStyle(eoFill: eoFill)
    }
}

private extension WaveformShape {
    private func damp(_ samples: [Float], with configuration: Waveform.Configuration) -> [Float] {
        guard let damping = configuration.damping, damping.percentage > 0 else {
            return samples
        }

        let count = Float(samples.count)
        return samples.enumerated().map { x, value -> Float in
            1 - ((1 - value) * dampFactor(x: Float(x), count: count, with: damping))
        }
    }

    private func dampFactor(x: Float, count: Float, with damping: Waveform.Damping) -> Float {
        if (damping.sides == .left || damping.sides == .both) && x < count * damping.percentage {
            // increasing linear damping within the left 8th (default)
            // basically (x : 1/8) with x in (0..<1/8)
            return damping.easing(x / (count * damping.percentage))
        } else if (damping.sides == .right || damping.sides == .both) && x > ((1 / damping.percentage) - 1) * (count * damping.percentage) {
            // decaying linear damping within the right 8th
            // basically also (x : 1/8), but since x in (7/8>...1) x is "inverted" as x = x - 7/8
            return damping.easing(1 - (x - (((1 / damping.percentage) - 1) * (count * damping.percentage))) / (count * damping.percentage))
        }
        return 1
    }
}

