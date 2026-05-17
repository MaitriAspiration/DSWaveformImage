import Foundation
import CoreGraphics

/**
 Draws a linear 2D amplitude envelope of the samples provided.

 Default `WaveformRenderer` used. Can be customized further via the configuration `Waveform.Style`.

 When constructed with `channelSelection: .stereo`, the renderer pulls samples laid out as
 `[allLeft..., allRight...]` and draws the left channel in the top half (extending upward from
 the midline) and the right channel in the bottom half (extending downward) — a single,
 self-contained stereo waveform image. The `sides` parameter is ignored in stereo mode.
 */
public struct LinearWaveformRenderer: ChannelAwareWaveformRenderer, SpectralAwareWaveformRenderer {
    /**
     Which side(s) of the centerline the envelope occupies. Ignored when `channelSelection == .stereo`.
     - `.both`: standard mirrored waveform (default).
     - `.up`: only the half above the centerline.
     - `.down`: only the half below the centerline.

     For `.striped` style, each stripe is drawn as a half-stripe from the centerline outward instead of a full top-to-bottom line.
     */
    public enum Sides: Sendable {
        case up, down, both
    }

    private let sides: Sides
    public let channelSelection: Waveform.ChannelSelection
    /// Per-column normalized spectral centroid in `[0, 1]`. Set via `withSpectralCentroids(_:)` by the
    /// drawer / view when the configured style is `.spectralTint`; otherwise unused.
    private let spectralCentroids: [Float]?

    /// Standard single-waveform renderer. For stereo two-channel rendering use `.stereo` instead.
    public init(sides: Sides = .both, channelSelection: Waveform.SingleChannelSelection = .merged) {
        self.sides = sides
        self.channelSelection = channelSelection.asChannelSelection
        self.spectralCentroids = nil
    }

    /// Internal init used by the `.stereo` factory. Not exposed publicly so the type system enforces
    /// that callers use the dedicated factory for stereo rendering.
    private init(stereoSides: Sides) {
        self.sides = stereoSides
        self.channelSelection = .stereo
        self.spectralCentroids = nil
    }

    /// Copy-init used by `withSpectralCentroids(_:)`.
    private init(sides: Sides, channelSelection: Waveform.ChannelSelection, spectralCentroids: [Float]?) {
        self.sides = sides
        self.channelSelection = channelSelection
        self.spectralCentroids = spectralCentroids
    }

    /// Renderer that interprets samples as `[allLeft..., allRight...]` (the layout produced by
    /// `Waveform.ChannelSelection.stereo`) and draws the left channel in the top half above the
    /// centerline and the right channel in the bottom half below — a single, self-contained stereo
    /// image.
    public static let stereo: LinearWaveformRenderer = LinearWaveformRenderer(stereoSides: .both)

    public func withSpectralCentroids(_ centroids: [Float]) -> WaveformRenderer {
        LinearWaveformRenderer(sides: sides, channelSelection: channelSelection, spectralCentroids: centroids)
    }

    public func path(samples: [Float], with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position = .middle) -> CGPath {
        guard channelSelection == .stereo else {
            return envelopePath(samples: samples, with: configuration, lastOffset: lastOffset, position: position, sides: sides)
        }

        // Stereo: samples come in as [allLeft..., allRight...]. Render the left half with `.up` so it
        // fills the top of the canvas, and the right half with `.down` so it fills the bottom — both
        // sharing the centerline. The user-provided `sides` is intentionally ignored here.
        let halfCount = samples.count / 2
        guard halfCount > 0 else { return CGMutablePath() }
        let leftSamples = Array(samples[0..<halfCount])
        let rightSamples = Array(samples[halfCount..<samples.count])

        let combined = CGMutablePath()
        combined.addPath(envelopePath(samples: leftSamples, with: configuration, lastOffset: lastOffset, position: position, sides: .up))
        combined.addPath(envelopePath(samples: rightSamples, with: configuration, lastOffset: lastOffset, position: position, sides: .down))
        return combined
    }

    public func render(samples: [Float], on context: CGContext, with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position = .middle) {
        if case let .spectralTint(low, high) = configuration.style {
            renderSpectralTint(samples: samples, low: low, high: high, on: context, with: configuration, position: position)
            return
        }
        context.addPath(path(samples: samples, with: configuration, lastOffset: lastOffset, position: position))
        defaultStyle(context: context, with: configuration)
    }

    /// Draws each amplitude column as its own stroked vertical line, colored by the spectral centroid
    /// at that slot (interpolated between `low` and `high`). The envelope shape is identical to the
    /// non-spectral path; only the fill differs. Stereo splits the sample array into two halves and
    /// recursively renders each in the appropriate half-canvas; spectral data is split the same way.
    private func renderSpectralTint(samples: [Float], low: DSColor, high: DSColor, on context: CGContext, with configuration: Waveform.Configuration, position: Waveform.Position) {
        if channelSelection == .stereo {
            let halfCount = samples.count / 2
            guard halfCount > 0 else { return }
            let leftSamples = Array(samples[0..<halfCount])
            let rightSamples = Array(samples[halfCount..<samples.count])
            let (leftCentroids, rightCentroids) = splitCentroidsForStereo(amplitudeHalfCount: halfCount)
            drawSpectralColumns(samples: leftSamples, centroids: leftCentroids, low: low, high: high, on: context, with: configuration, position: position, drawSides: .up)
            drawSpectralColumns(samples: rightSamples, centroids: rightCentroids, low: low, high: high, on: context, with: configuration, position: position, drawSides: .down)
            return
        }
        drawSpectralColumns(samples: samples, centroids: spectralCentroids, low: low, high: high, on: context, with: configuration, position: position, drawSides: sides)
    }

    private func splitCentroidsForStereo(amplitudeHalfCount: Int) -> ([Float]?, [Float]?) {
        guard let centroids = spectralCentroids, centroids.count >= amplitudeHalfCount * 2 else {
            return (spectralCentroids, spectralCentroids)
        }
        return (Array(centroids[0..<amplitudeHalfCount]), Array(centroids[amplitudeHalfCount..<amplitudeHalfCount * 2]))
    }

    private func drawSpectralColumns(samples: [Float], centroids: [Float]?, low: DSColor, high: DSColor, on context: CGContext, with configuration: Waveform.Configuration, position: Waveform.Position, drawSides: Sides) {
        guard !samples.isEmpty else { return }
        let graphRect = CGRect(origin: .zero, size: configuration.size)
        let center = position.offset() * graphRect.size.height
        let drawMappingFactor = graphRect.size.height * configuration.verticalScalingFactor
        let minAmp: CGFloat = 1 / configuration.scale
        let samplesNeeded = Int(configuration.size.width * configuration.scale)
        let xOffset = CGFloat(samplesNeeded - samples.count) / configuration.scale
        let lineWidth: CGFloat = 1 / configuration.scale

        context.saveGState()
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)

        let lowComponents = rgbaComponents(of: low)
        let highComponents = rgbaComponents(of: high)
        // No centroid data → uniform `low` color (degraded, but never crashes or produces blank output).
        let hasCentroids = (centroids?.count ?? 0) >= samples.count

        for (i, sample) in samples.enumerated() {
            let xPos = CGFloat(i) / configuration.scale + xOffset
            let invertedDb = 1 - CGFloat(sample)
            let amp = max(minAmp, invertedDb * drawMappingFactor)
            let up = center - amp
            let down = center + amp

            let t: CGFloat = hasCentroids ? CGFloat(centroids![i]) : 0
            let color = LinearWaveformRenderer.interpolatedColor(low: lowComponents, high: highComponents, t: t)
            context.setStrokeColor(color)

            switch drawSides {
            case .up:
                context.move(to: CGPoint(x: xPos, y: center))
                context.addLine(to: CGPoint(x: xPos, y: up))
            case .down:
                context.move(to: CGPoint(x: xPos, y: center))
                context.addLine(to: CGPoint(x: xPos, y: down))
            case .both:
                context.move(to: CGPoint(x: xPos, y: up))
                context.addLine(to: CGPoint(x: xPos, y: down))
            }
            context.strokePath()
        }

        context.restoreGState()
    }

    private static func interpolatedColor(low: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat), high: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat), t: CGFloat) -> CGColor {
        let clamped = max(0, min(1, t))
        let r = low.r + (high.r - low.r) * clamped
        let g = low.g + (high.g - low.g) * clamped
        let b = low.b + (high.b - low.b) * clamped
        let a = low.a + (high.a - low.a) * clamped
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private func rgbaComponents(of color: DSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        // NSColor.getRed(…) requires a calibrated/device RGB color; system colors aren't.
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return (r, g, b, a)
    }

    private func envelopePath(samples: [Float], with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position, sides: Sides) -> CGPath {
        let graphRect = CGRect(origin: CGPoint.zero, size: configuration.size)
        let positionAdjustedGraphCenter = position.offset() * graphRect.size.height
        let samplesNeeded = Int(configuration.size.width * configuration.scale)
        let xOffset = CGFloat(samplesNeeded - samples.count) / configuration.scale
        var path = CGMutablePath()

        // Anchor the closing point of the envelope at the actual x position of the first/last sample.
        // When `samples.count != samplesNeeded` (e.g. during a resize before re-sampling completes),
        // starting at x=0 would leave diagonal lines between (0, center) and the first/last samples
        // that show up as a triangular notch in the filled envelope.
        path.move(to: CGPoint(x: xOffset, y: positionAdjustedGraphCenter))

        if case .striped = configuration.style {
            // Each stripe is its own move+line subpath; `sides` controls whether the stripe spans
            // both halves (`.both`) or only one half from the centerline outward.
            path = draw(samples: samples, path: path, with: configuration, lastOffset: lastOffset, sides: sides, position: position)
        } else {
            switch sides {
            case .up:
                path = draw(samples: samples, path: path, with: configuration, lastOffset: lastOffset, sides: .up, position: position)
                // Close the polygon along the right edge and then back along the centerline.
                path.addLine(to: CGPoint(x: configuration.size.width, y: positionAdjustedGraphCenter))
            case .down:
                // Extend along the centerline first so the .down envelope's first segment is a clean
                // vertical drop at the right edge (rather than a long diagonal across the canvas).
                path.addLine(to: CGPoint(x: configuration.size.width, y: positionAdjustedGraphCenter))
                path = draw(samples: samples.reversed(), path: path, with: configuration, lastOffset: lastOffset, sides: .down, position: position)
            case .both:
                path = draw(samples: samples, path: path, with: configuration, lastOffset: lastOffset, sides: .up, position: position)
                path = draw(samples: samples.reversed(), path: path, with: configuration, lastOffset: lastOffset, sides: .down, position: position)
            }
        }

        path.closeSubpath()
        return path
    }

    private func stripeBucket(_ configuration: Waveform.Configuration) -> Int {
        if case let .striped(stripeConfig) = configuration.style {
            return Int(stripeConfig.width + stripeConfig.spacing) * Int(configuration.scale)
        } else {
            return 0
        }
    }

    private func draw(samples: [Float], path: CGMutablePath, with configuration: Waveform.Configuration, lastOffset: Int, sides: Sides, position: Waveform.Position = .middle) -> CGMutablePath {
        let graphRect = CGRect(origin: CGPoint.zero, size: configuration.size)
        let positionAdjustedGraphCenter = position.offset() * graphRect.size.height
        let drawMappingFactor = graphRect.size.height * configuration.verticalScalingFactor
        let minimumGraphAmplitude: CGFloat = 1 / configuration.scale // we want to see at least a 1px line for silence
        let isStriped: Bool = { if case .striped = configuration.style { return true } else { return false } }()
        var lastXPos: CGFloat = 0

        for (index, sample) in samples.enumerated() {
            let adjustedIndex: Int
            // For non-striped + .down we reverse the iteration direction so the bottom envelope traverses
            // right-to-left, which lets it connect into the upper envelope's last point for `.both`.
            // For striped, each stripe is its own subpath so direction is irrelevant — keep natural order
            // so samples passed in unreversed land at their natural x positions.
            if !isStriped && sides == .down {
                adjustedIndex = samples.count - index
            } else {
                adjustedIndex = index
            }

            var x = adjustedIndex + lastOffset
            if isStriped, x % Int(configuration.scale) != 0 || x % stripeBucket(configuration) != 0 {
                // skip sub-pixels - any x value not scale aligned
                // skip any point that is not a multiple of our bucket width (width + spacing)
                continue
            } else if case let .striped(config) = configuration.style {
                // ensure 1st stripe is drawn completely inside bounds and does not clip half way on the left side
                x += Int(config.width / 2 * configuration.scale)
            }

            let samplesNeeded = Int(configuration.size.width * configuration.scale)
            let xOffset = CGFloat(samplesNeeded - samples.count) / configuration.scale // When there's extra space, draw waveform on the right
            let xPos = (CGFloat(x - lastOffset) / configuration.scale) + xOffset
            let invertedDbSample = 1 - CGFloat(sample) // sample is in dB, linearly normalized to [0, 1] (1 -> -50 dB)
            let drawingAmplitude = max(minimumGraphAmplitude, invertedDbSample * drawMappingFactor)
            let drawingAmplitudeUp = positionAdjustedGraphCenter - drawingAmplitude
            let drawingAmplitudeDown = positionAdjustedGraphCenter + drawingAmplitude
            lastXPos = xPos

            switch sides {
            case .up:
                // Striped: each stripe is its own move+line from centerline to the upper envelope.
                // Non-striped: extend the running envelope line up.
                if isStriped {
                    path.move(to: CGPoint(x: xPos, y: positionAdjustedGraphCenter))
                }
                path.addLine(to: CGPoint(x: xPos, y: drawingAmplitudeUp))

            case .down:
                if isStriped {
                    path.move(to: CGPoint(x: xPos, y: positionAdjustedGraphCenter))
                }
                path.addLine(to: CGPoint(x: xPos, y: drawingAmplitudeDown))

            case .both:
                path.move(to: CGPoint(x: xPos, y: drawingAmplitudeUp))
                path.addLine(to: CGPoint(x: xPos, y: drawingAmplitudeDown))
            }
        }

        if isStriped {
            path.move(to: CGPoint(x: lastXPos, y: positionAdjustedGraphCenter))
        }

        return path
    }
}
