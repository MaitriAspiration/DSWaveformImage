import DSWaveformImage
import DSWaveformImageViews
import SwiftUI

/// Modernized SwiftUI progress demo. Shared across iOS, macOS, and visionOS examples.
@available(iOS 15.0, macOS 12.0, *)
public struct ProgressShowcase: View {
    public init() {}

    public var body: some View {
        GalleryScrollView {
            GalleryHero(
                title: "Progress",
                subtitle: "Visualize playback position by drawing the waveform once and overlaying a progress-clipped tint on top."
            )
            InteractiveScrubSection()
            AutoplaySection()
            StyleVariantsSection()
        }
    }
}

// MARK: - Interactive scrub

@available(iOS 15.0, macOS 12.0, *)
private struct InteractiveScrubSection: View {
    private let url = SampleAudio.stereoDemo
    @State private var progress: Double = 0.35

    var body: some View {
        GallerySection(
            "Scrub",
            systemImage: "slider.horizontal.below.rectangle",
            subtitle: "Drag the slider — only the foreground tint is masked. The underlying waveform stays static."
        ) {
            WaveformCard(caption: "WaveformView(audioURL: …) { shape in shape.fill(.…) }") {
                VStack(spacing: 16) {
                    ProgressWaveform(
                        audioURL: url,
                        progress: progress,
                        baseColor: .secondary,
                        progressColor: .accentColor
                    )
                    .frame(height: 120)

                    Slider(value: $progress, in: 0...1)
                }
            }
        }
    }
}

// MARK: - Autoplay

@available(iOS 15.0, macOS 12.0, *)
private struct AutoplaySection: View {
    private let url = SampleAudio.stereoDemo
    @State private var progress: Double = 0
    @State private var playing: Bool = false

    var body: some View {
        GallerySection(
            "Auto-advance",
            systemImage: "play.circle.fill",
            subtitle: "Drive `progress` from your audio player's time observer. Smooth updates fall out for free — no animation needed when ticks come every ~50ms."
        ) {
            WaveformCard {
                VStack(spacing: 16) {
                    ProgressWaveform(
                        audioURL: url,
                        progress: progress,
                        baseColor: Color(white: 0.7),
                        progressColor: .pink
                    )
                    .frame(height: 100)

                    HStack(spacing: 12) {
                        Button {
                            playing.toggle()
                        } label: {
                            Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                progress = .random(in: 0...1)
                            }
                        } label: {
                            Label("Shuffle", systemImage: "dice.fill")
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: playing) {
            // Simulate a player by ticking progress forward at ~60 Hz while playing.
            guard playing else { return }
            let stepInterval: UInt64 = 16_000_000 // ~16ms
            let totalDuration: Double = 6
            let stepValue: Double = 16.0 / 1000.0 / totalDuration

            while playing {
                try? await Task.sleep(nanoseconds: stepInterval)
                guard playing else { break }
                await MainActor.run {
                    progress = min(1, progress + stepValue)
                    if progress >= 1 { playing = false }
                }
            }
        }
    }
}

// MARK: - Style variants

@available(iOS 15.0, macOS 12.0, *)
private struct StyleVariantsSection: View {
    private let url = SampleAudio.stereoDemo
    @State private var progress: Double = 0.55

    var body: some View {
        GallerySection(
            "Style variants",
            systemImage: "paintpalette",
            subtitle: "The same masking technique drops into any color or gradient — only the foreground fill changes."
        ) {
            LazyVStack(spacing: 12) {
                WaveformCard("Indigo on graphite", caption: "shape.fill(.indigo)") {
                    ProgressWaveform(
                        audioURL: url,
                        progress: progress,
                        baseColor: Color(white: 0.55),
                        progressColor: .indigo
                    )
                    .frame(height: 90)
                }
                WaveformCard("Sunset gradient", caption: ".fill(LinearGradient([.orange, .pink], …))") {
                    ProgressWaveform(
                        audioURL: url,
                        progress: progress,
                        baseColor: Color.gray.opacity(0.35),
                        progressFill: .linearGradient(
                            colors: [.orange, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 90)
                }
                WaveformCard("Striped overlay", caption: ".striped(.init(color: .systemTeal, width: 3))") {
                    ProgressWaveformStriped(audioURL: url, progress: progress)
                        .frame(height: 90)
                }

                Slider(value: $progress, in: 0...1)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Building blocks

/// Solid base + a single masked foreground stroke/fill. The foreground is the only thing that
/// reacts to `progress`, so updates stay cheap.
@available(iOS 15.0, macOS 12.0, *)
private struct ProgressWaveform<Foreground: ShapeStyle>: View {
    let audioURL: URL
    let progress: Double
    let baseColor: Color
    let progressFill: Foreground

    init(audioURL: URL, progress: Double, baseColor: Color, progressColor: Color) where Foreground == Color {
        self.audioURL = audioURL
        self.progress = progress
        self.baseColor = baseColor
        self.progressFill = progressColor
    }

    init(audioURL: URL, progress: Double, baseColor: Color, progressFill: Foreground) {
        self.audioURL = audioURL
        self.progress = progress
        self.baseColor = baseColor
        self.progressFill = progressFill
    }

    var body: some View {
        GeometryReader { geometry in
            WaveformView(audioURL: audioURL) { shape in
                shape.fill(baseColor)
                shape.fill(progressFill).mask(alignment: .leading) {
                    Rectangle().frame(width: geometry.size.width * progress)
                }
            }
        }
    }
}

/// Striped variant uses the built-in `.striped` style for the base, so each bar shows individually
/// — then the foreground draws the same shape filled and masked.
@available(iOS 15.0, macOS 12.0, *)
private struct ProgressWaveformStriped: View {
    let audioURL: URL
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                WaveformView(
                    audioURL: audioURL,
                    configuration: .init(style: .striped(.init(color: .systemGray, width: 3, spacing: 3)))
                )
                WaveformView(
                    audioURL: audioURL,
                    configuration: .init(style: .striped(.init(color: .systemTeal, width: 3, spacing: 3)))
                )
                .mask(alignment: .leading) {
                    Rectangle().frame(width: geometry.size.width * progress)
                }
            }
        }
    }
}

#if DEBUG
@available(iOS 15.0, macOS 12.0, *)
struct ProgressShowcase_Previews: PreviewProvider {
    static var previews: some View {
        ProgressShowcase()
    }
}
#endif
