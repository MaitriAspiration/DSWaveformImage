import Foundation
import CoreGraphics

/**
 Draws a circular 2D amplitude envelope of the samples provided.

 Draws either a filled circle, or a hollow ring, depending on the provided `Kind`. Defaults to drawing a `.circle`.
 Can be customized further via the configuration `Waveform.Style`.
 */

public struct CircularWaveformRenderer: WaveformRenderer {
    public enum Kind: Sendable {
        /// Draws waveform as a circular amplitude envelope.
        case circle

        /// Draws waveform as a ring-shaped amplitude envelope, where the modulated outer envelope
        /// extends from a fixed inner circle outward toward the maximum radius.
        /// The associated value sets the inner circle's radius as a fraction of the overall radius
        /// (e.g. `0.5` = inner radius is half of the maximum). Clamped to `(0...1)` is the caller's
        /// responsibility — `0` collapses to `.circle`, `1` collapses to a zero-thickness ring.
        case ring(CGFloat)
    }

    public let kind: Kind

    public init(kind: Kind = .circle) {
        self.kind = kind
    }

    /// Whether `fill` / `clip` over this renderer's path needs the even-odd rule to produce the
    /// intended region. `true` for `.ring`, because the path consists of an outer envelope and an
    /// inner circle subpath whose subtraction can't be guaranteed by winding direction alone.
    public var prefersEvenOddFillRule: Bool {
        if case .ring = kind { return true }
        return false
    }

    public func path(samples: [Float], with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position = .middle) -> CGPath {
        switch kind {
        case .circle: return circlePath(samples: samples, with: configuration, lastOffset: lastOffset, position: position)
        case .ring: return ringPath(samples: samples, with: configuration, lastOffset: lastOffset, position: position)
        }
    }

    public func render(samples: [Float], on context: CGContext, with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position = .middle) {
        let path = path(samples: samples, with: configuration, lastOffset: lastOffset)
        context.addPath(path)

        style(context: context, with: configuration)
    }

    func style(context: CGContext, with configuration: Waveform.Configuration) {
        // The ring path is two subpaths (outer envelope + inner circle). Region-based ops (fill,
        // clip) must use even-odd so the annulus is produced regardless of subpath direction —
        // non-zero winding would require both subpaths to wind opposite ways, which we can't
        // guarantee across CG versions for `addEllipse`.
        let isRing: Bool = { if case .ring = kind { return true } else { return false } }()

        switch configuration.style {
        case let .gradient(colors):
            if isRing {
                context.clip(using: .evenOdd)
            } else {
                context.clip()
            }
            let colors = NSArray(array: colors.map { (color: DSColor) -> CGColor in color.cgColor }) as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: nil)!
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: configuration.size.height),
                                       options: .drawsAfterEndLocation)

        case let .filled(color) where isRing:
            context.setLineWidth(1.0 / configuration.scale)
            context.setFillColor(color.cgColor)
            context.fillPath(using: .evenOdd)

        default:
            defaultStyle(context: context, with: configuration)
        }
    }

    private func circlePath(samples: [Float], with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position) -> CGPath {
        let graphRect = CGRect(origin: .zero, size: configuration.size)
        let maxRadius = CGFloat(min(graphRect.maxX, graphRect.maxY) / 2.0) * configuration.verticalScalingFactor
        let center = CGPoint(
            x: graphRect.maxX * position.offset(),
            y: graphRect.maxY * position.offset()
        )
        let path = CGMutablePath()

        path.move(to: center)

        for (index, sample) in samples.enumerated() {
            let angle = CGFloat.pi * 2 * (CGFloat(index) / CGFloat(samples.count))
            let x = index + lastOffset

            if case .striped = configuration.style, x % Int(configuration.scale) != 0 || x % stripeBucket(configuration) != 0 {
                // skip sub-pixels - any x value not scale aligned
                // skip any point that is not a multiple of our bucket width (width + spacing)
                path.addLine(to: center)
                continue
            }

            let invertedDbSample = 1 - CGFloat(sample) // sample is in dB, linearly normalized to [0, 1] (1 -> -50 dB)
            let pointOnCircle = CGPoint(
                x: center.x + maxRadius * invertedDbSample * cos(angle),
                y: center.y + maxRadius * invertedDbSample * sin(angle)
            )

            path.addLine(to: pointOnCircle)
        }

        path.closeSubpath()
        return path
    }

    private func ringPath(samples: [Float], with configuration: Waveform.Configuration, lastOffset: Int, position: Waveform.Position) -> CGPath {
        guard case let .ring(config) = kind else {
            fatalError("called with wrong kind")
        }
        guard !samples.isEmpty else { return CGMutablePath() }

        let graphRect = CGRect(origin: .zero, size: configuration.size)
        let maxRadius = CGFloat(min(graphRect.maxX, graphRect.maxY) / 2.0) * configuration.verticalScalingFactor
        let innerRadius: CGFloat = maxRadius * config
        let ringThickness = maxRadius - innerRadius
        // Mirrors `LinearWaveformRenderer`'s `minimumGraphAmplitude` — guarantees the ring stays
        // at least 1 device pixel thick at silence (sample == 1 → invertedDbSample == 0), so the
        // ring is always visible. Clamped to `ringThickness` for the degenerate `.ring(1)` case
        // where there's no room to extend outward at all.
        let minimumRadialAmplitude: CGFloat = min(ringThickness, 1 / configuration.scale)
        let center = CGPoint(
            x: graphRect.maxX * position.offset(),
            y: graphRect.maxY * position.offset()
        )
        let path = CGMutablePath()

        if case .striped = configuration.style {
            // Each visible stripe is its own move(inner) + line(outer) subpath — drawn radially
            // at the sample's angle, with `defaultStyle` translating it into a stroked stripe.
            for (index, sample) in samples.enumerated() {
                let x = index + lastOffset
                if x % Int(configuration.scale) != 0 || x % stripeBucket(configuration) != 0 {
                    continue
                }

                let angle = CGFloat.pi * 2 * (CGFloat(index) / CGFloat(samples.count))
                let invertedDbSample = 1 - CGFloat(sample)
                let radialAmplitude = max(minimumRadialAmplitude, ringThickness * invertedDbSample)
                let inner = CGPoint(
                    x: center.x + innerRadius * cos(angle),
                    y: center.y + innerRadius * sin(angle)
                )
                let outer = CGPoint(
                    x: inner.x + radialAmplitude * cos(angle),
                    y: inner.y + radialAmplitude * sin(angle)
                )
                path.move(to: inner)
                path.addLine(to: outer)
            }
            return path
        }

        // Non-striped: build an annulus from two subpaths — the outer envelope and the inner
        // circle. `style(...)` uses the even-odd fill rule for filled/gradient so the inner
        // disk is excluded regardless of subpath winding direction; outlined / gradientOutlined
        // simply stroke both subpaths' outlines.
        for (index, sample) in samples.enumerated() {
            let angle = CGFloat.pi * 2 * (CGFloat(index) / CGFloat(samples.count))
            let invertedDbSample = 1 - CGFloat(sample) // sample is in dB, linearly normalized to [0, 1] (1 -> -50 dB)
            let radialAmplitude = max(minimumRadialAmplitude, ringThickness * invertedDbSample)
            let radius = innerRadius + radialAmplitude
            let pointOnEnvelope = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            if index == 0 {
                path.move(to: pointOnEnvelope)
            } else {
                path.addLine(to: pointOnEnvelope)
            }
        }
        path.closeSubpath()

        path.addEllipse(in: CGRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))

        return path
    }

    private func stripeBucket(_ configuration: Waveform.Configuration) -> Int {
        if case let .striped(stripeConfig) = configuration.style {
            return Int(stripeConfig.width + stripeConfig.spacing) * Int(configuration.scale)
        } else {
            return 0
        }
    }
}
