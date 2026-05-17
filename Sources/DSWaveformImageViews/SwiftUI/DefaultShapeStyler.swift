import Foundation
import DSWaveformImage
import SwiftUI

struct DefaultShapeStyler {
    @ViewBuilder
    func style(shape: WaveformShape, with configuration: Waveform.Configuration) -> some View {
        switch configuration.style {
        case let .filled(color):
            shape.fill(Color(color), style: shape.fillStyle)

        case let .outlined(color, lineWidth):
            shape.stroke(
                Color(color),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round
                )
            )

        case let .gradient(colors):
            shape
                .fill(
                    LinearGradient(colors: colors.map(Color.init), startPoint: .bottom, endPoint: .top),
                    style: shape.fillStyle
                )

        case let .gradientOutlined(colors, lineWidth):
            shape.stroke(
                LinearGradient(colors: colors.map(Color.init), startPoint: .bottom, endPoint: .top),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round
                )
            )

        case let .striped(config):
            shape.stroke(
                Color(config.color),
                style: StrokeStyle(
                    lineWidth: config.width,
                    lineCap: config.lineCap
                )
            )

        case let .spectralTint(low, _):
            // `WaveformView` renders `.spectralTint` via its own Canvas path (so per-column tinting
            // works), so this branch is only reached if a caller passes the styler a spectral-styled
            // shape directly. Fall back to filling the envelope with `low` — degraded, but never blank.
            shape.fill(Color(low), style: shape.fillStyle)
        }
    }
}
