import DSWaveformImage
import DSWaveformImageViews
import SwiftUI

/// A curated showcase of every public surface the library offers. Shared across the iOS, macOS, and
/// visionOS example apps.
@available(iOS 15.0, macOS 12.0, *)
public struct WaveformGalleryView: View {
    public init() {}

    public var body: some View {
        // GalleryScrollView wraps the sections in a LazyVStack so sections only instantiate when
        // scrolled into view — keeps the number of concurrent `WaveformView` analyses small. macOS
        // AVFoundation hangs when too many AVAssetReader instances target the same audio URL
        // simultaneously.
        GalleryScrollView {
            GalleryHero(
                title: "DSWaveformImage",
                subtitle: "A tour of the rendering surface — pulse-modulated stereo demo audio throughout."
            )
            PlaygroundSection()
            RenderersSection()
            StylesSection()
            SpectralSection()
            ChannelsSection()
            CustomShapeSection()
        }
    }
}

// MARK: - Playground (interactive)

@available(iOS 15.0, macOS 12.0, *)
private struct PlaygroundSection: View {
    enum RendererChoice: String, CaseIterable, Identifiable {
        case linear = "Linear"
        case stereo = "Stereo"
        case circle = "Circle"
        case ring = "Ring"
        var id: Self { self }
    }

    enum StyleChoice: String, CaseIterable, Identifiable {
        case filled = "Filled"
        case outlined = "Outlined"
        case gradient = "Gradient"
        case striped = "Striped"
        var id: Self { self }
    }

    enum ScalingChoice: String, CaseIterable, Identifiable {
        case absolute = "Absolute"
        case normalized = "Normalized"
        var id: Self { self }

        var value: Waveform.AmplitudeScaling {
            switch self {
            case .absolute: return .absolute
            case .normalized: return .normalized
            }
        }
    }

    @State private var renderer: RendererChoice = .linear
    @State private var style: StyleChoice = .gradient
    @State private var scaling: ScalingChoice = .absolute
    @State private var damped: Bool = true
    @State private var color: Color = .indigo

    var body: some View {
        GallerySection("Playground", systemImage: "slider.horizontal.3", subtitle: "Pick a renderer, style, and amplitude scaling — the same configuration drives the preview below.") {
            VStack(spacing: 16) {
                WaveformCard(descriptor) {
                    WaveformView(
                        audioURL: SampleAudio.stereoDemo,
                        configuration: configuration,
                        renderer: rendererInstance
                    )
                    .frame(height: 220)
                }

                controls
            }
        }
    }

    // MARK: Configuration

    private var configuration: Waveform.Configuration {
        Waveform.Configuration(
            style: styleInstance,
            damping: damped ? .init(percentage: 0.125, sides: .both) : nil,
            amplitudeScaling: scaling.value
        )
    }

    private var rendererInstance: WaveformRenderer {
        switch renderer {
        case .linear: return LinearWaveformRenderer()
        case .stereo: return LinearWaveformRenderer.stereo
        case .circle: return CircularWaveformRenderer(kind: .circle)
        case .ring: return CircularWaveformRenderer(kind: .ring(0.5))
        }
    }

    private var styleInstance: Waveform.Style {
        let primary = DSColor(color)
        let secondary = DSColor(color.opacity(0.4))
        switch style {
        case .filled: return .filled(primary)
        case .outlined: return .outlined(primary, 1.5)
        case .gradient: return .gradient([primary, secondary])
        case .striped: return .striped(.init(color: primary, width: 2, spacing: 3))
        }
    }

    private var descriptor: String {
        "\(renderer.rawValue) · \(style.rawValue.lowercased()) · \(scaling.rawValue.lowercased())\(damped ? " · damped" : "")"
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 14) {
            controlBlock("Renderer") {
                Picker("Renderer", selection: $renderer) {
                    ForEach(RendererChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            controlBlock("Style") {
                Picker("Style", selection: $style) {
                    ForEach(StyleChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            controlBlock("Amplitude scaling") {
                Picker("Amplitude scaling", selection: $scaling) {
                    ForEach(ScalingChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(spacing: 12) {
                Toggle("Damping", isOn: $damped)
                    .toggleStyle(.switch)
                    .font(.subheadline.weight(.medium))
                Spacer()
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36, height: 36)
            }
        }
        .padding(WaveformGalleryStyle.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: WaveformGalleryStyle.cardCornerRadius, style: .continuous)
                .fill(WaveformGalleryStyle.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WaveformGalleryStyle.cardCornerRadius, style: .continuous)
                .strokeBorder(WaveformGalleryStyle.subtleStroke, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func controlBlock<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

// MARK: - Renderers gallery

@available(iOS 15.0, macOS 12.0, *)
private struct RenderersSection: View {
    private let url = SampleAudio.stereoDemo
    private let baseConfig = Waveform.Configuration(style: .gradient([.systemBlue, .systemIndigo]), damping: .init(percentage: 0.125, sides: .both))

    var body: some View {
        GallerySection("Renderers", systemImage: "waveform", subtitle: "Each renderer produces a different geometric layout from the same samples.") {
            LazyVStack(spacing: 12) {
                WaveformCard("Linear · default", caption: "LinearWaveformRenderer()") {
                    WaveformView(audioURL: url, configuration: baseConfig)
                        .frame(height: 100)
                }
                WaveformCard("Linear · top-only", caption: "LinearWaveformRenderer(sides: .up)") {
                    WaveformView(audioURL: url, configuration: baseConfig, renderer: LinearWaveformRenderer(sides: .up))
                        .frame(height: 100)
                }
                WaveformCard("Linear · bottom-only", caption: "LinearWaveformRenderer(sides: .down)") {
                    WaveformView(audioURL: url, configuration: baseConfig, renderer: LinearWaveformRenderer(sides: .down))
                        .frame(height: 100)
                }
                WaveformCard("Circular", caption: "CircularWaveformRenderer(kind: .circle)") {
                    WaveformView(audioURL: url, configuration: baseConfig, renderer: CircularWaveformRenderer(kind: .circle))
                        .frame(height: 220)
                }
                WaveformCard("Ring", caption: "CircularWaveformRenderer(kind: .ring(0.5))") {
                    WaveformView(audioURL: url, configuration: baseConfig, renderer: CircularWaveformRenderer(kind: .ring(0.5)))
                        .frame(height: 220)
                }
            }
        }
    }
}

// MARK: - Styles gallery

@available(iOS 15.0, macOS 12.0, *)
private struct StylesSection: View {
    private let url = SampleAudio.stereoDemo

    private struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let caption: String
        let style: Waveform.Style
    }

    private var entries: [Entry] {
        [
            .init(title: "Filled", caption: ".filled(.systemIndigo)", style: .filled(.systemIndigo)),
            .init(title: "Outlined", caption: ".outlined(.systemIndigo, 1)", style: .outlined(.systemIndigo, 1)),
            .init(title: "Gradient", caption: ".gradient([.systemBlue, .systemPurple])", style: .gradient([.systemBlue, .systemPurple])),
            .init(title: "Gradient outlined", caption: ".gradientOutlined([.systemBlue, .systemPurple], 1)", style: .gradientOutlined([.systemBlue, .systemPurple], 1)),
            .init(title: "Striped", caption: ".striped(.init(color: .systemIndigo, width: 2, spacing: 2))", style: .striped(.init(color: .systemIndigo, width: 2, spacing: 2))),
        ]
    }

    var body: some View {
        GallerySection("Styles", systemImage: "paintbrush.pointed", subtitle: "Configuration.style controls how the envelope is drawn — same renderer throughout.") {
            LazyVStack(spacing: 12) {
                ForEach(entries) { entry in
                    WaveformCard(entry.title, caption: entry.caption) {
                        WaveformView(audioURL: url, configuration: .init(style: entry.style, damping: .init(percentage: 0.125, sides: .both)))
                            .frame(height: 90)
                    }
                }
            }
        }
    }
}

// MARK: - Spectral gallery

@available(iOS 15.0, macOS 12.0, *)
private struct SpectralSection: View {
    // The stereo demo only has two pure tones, which gives a flat tint. The 12-second mix has bass,
    // mids, and highs spread over time so the color sweeps visibly across the gradient.
    private let url = SampleAudio.stereoDemo

    private struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let caption: String
        let low: DSColor
        let high: DSColor
    }

    private var entries: [Entry] {
        [
            .init(title: "Cool → warm", caption: ".spectralTint(low: .systemBlue, high: .systemRed)", low: .systemBlue, high: .systemRed),
            .init(title: "Indigo → mint", caption: ".spectralTint(low: .systemIndigo, high: .systemMint)", low: .systemIndigo, high: .systemMint),
        ]
    }

    var body: some View {
        GallerySection(
            "Spectral tint",
            systemImage: "rainbow",
            subtitle: "Colors each column by the spectral centroid at that moment — bass-heavy slots take the low color, treble-heavy slots take the high color. Same envelope, but the fill follows the audio's frequency content."
        ) {
            LazyVStack(spacing: 12) {
                ForEach(entries) { entry in
                    WaveformCard(entry.title, caption: entry.caption) {
                        WaveformView(
                            audioURL: url,
                            configuration: .init(
                                style: .spectralTint(low: entry.low, high: entry.high),
                                damping: .init(percentage: 0.125, sides: .both)
                            )
                        )
                        .frame(height: 120)
                    }
                }
            }
        }
    }
}

// MARK: - Channels gallery

@available(iOS 15.0, macOS 12.0, *)
private struct ChannelsSection: View {
    private let url = SampleAudio.stereoDemo

    var body: some View {
        GallerySection("Channel selection", systemImage: "speaker.wave.2", subtitle: "The renderer decides which channel(s) of the audio it interprets. The demo file's L and R have clearly distinct envelopes.") {
            LazyVStack(spacing: 12) {
                WaveformCard("Merged (default)", caption: "LinearWaveformRenderer()") {
                    WaveformView(audioURL: url, configuration: .init(style: .filled(.systemGray)))
                        .frame(height: 90)
                }
                WaveformCard("Specific(0) — left", caption: "LinearWaveformRenderer(channelSelection: .specific(0))") {
                    WaveformView(
                        audioURL: url,
                        configuration: .init(style: .filled(.systemBlue)),
                        renderer: LinearWaveformRenderer(channelSelection: .specific(0))
                    )
                    .frame(height: 90)
                }
                WaveformCard("Specific(1) — right", caption: "LinearWaveformRenderer(channelSelection: .specific(1))") {
                    WaveformView(
                        audioURL: url,
                        configuration: .init(style: .filled(.systemRed)),
                        renderer: LinearWaveformRenderer(channelSelection: .specific(1))
                    )
                    .frame(height: 90)
                }
                WaveformCard("Stereo", caption: "LinearWaveformRenderer.stereo") {
                    WaveformView(
                        audioURL: url,
                        configuration: .init(style: .gradient([.systemBlue, .systemRed])),
                        renderer: LinearWaveformRenderer.stereo
                    )
                    .frame(height: 160)
                }
            }
        }
    }
}

// MARK: - Custom shape gallery

@available(iOS 15.0, macOS 12.0, *)
private struct CustomShapeSection: View {
    private let url = SampleAudio.stereoDemo
    @State private var samples: [Float] = []

    var body: some View {
        GallerySection("Custom shape", systemImage: "wand.and.rays", subtitle: "Use WaveformView's trailing closure to fully restyle the Shape, or instantiate WaveformShape directly when you already have samples.") {
            LazyVStack(spacing: 12) {
                WaveformCard("Stroke override on WaveformView", caption: "{ shape in shape.stroke(…) }") {
                    WaveformView(audioURL: url, configuration: .init(style: .striped(.init(color: .systemIndigo, width: 3)))) { shape in
                        shape.stroke(
                            LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                    }
                    .frame(height: 120)
                }
                WaveformCard("Bare WaveformShape", caption: "WaveformShape(samples: …).fill(LinearGradient(…))") {
                    GeometryReader { geometry in
                        WaveformShape(samples: samples)
                            .fill(LinearGradient(colors: [.orange, .pink], startPoint: .top, endPoint: .bottom))
                            .task(id: geometry.size.width) {
                                await loadSamples(width: geometry.size.width)
                            }
                    }
                    .frame(height: 120)
                }
            }
        }
    }

    private func loadSamples(width: CGFloat) async {
        guard width > 0 else { return }
        do {
            let count = Int(width * DSScreen.scale)
            let loaded = try await WaveformAnalyzer().samples(fromAudioAt: url, count: count)
            await MainActor.run { samples = loaded }
        } catch {
            assertionFailure("Failed to analyze \(url): \(error)")
        }
    }
}
