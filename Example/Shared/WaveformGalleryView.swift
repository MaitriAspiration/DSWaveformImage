import DSWaveformImage
import DSWaveformImageViews
import SwiftUI

/// A curated showcase of every public surface the library offers. Shared across the iOS, macOS, and
/// visionOS example apps.
@available(iOS 15.0, macOS 12.0, *)
public struct WaveformGalleryView: View {
    public init() {}

    public var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                // LazyVStack so sections only instantiate when scrolled into view — keeps the number
                // of concurrent `WaveformView` analyses small. macOS AVFoundation hangs when too many
                // AVAssetReader instances target the same audio URL simultaneously.
                LazyVStack(alignment: .leading, spacing: 28) {
                    HeroSection()
                    PlaygroundSection()
                    RenderersSection()
                    StylesSection()
                    ChannelsSection()
                    CustomShapeSection()
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: 720)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(WaveformGalleryStyle.backgroundFill.ignoresSafeArea())
    }
}

// MARK: - Shared style constants

@available(iOS 15.0, macOS 12.0, *)
enum WaveformGalleryStyle {
    static let cardCornerRadius: CGFloat = 16
    static let cardPadding: CGFloat = 16

    static var cardFill: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var backgroundFill: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static let subtleStroke = Color.gray.opacity(0.18)
}

// MARK: - Audio assets

@available(iOS 15.0, macOS 12.0, *)
private enum SampleAudio {
    /// Synthetic 6-second stereo clip: left = 3 long tone pulses (440 Hz), right = 6 short pulses (659 Hz).
    static let stereoDemo: URL = Bundle.main.url(forResource: "example_stereo", withExtension: "m4a")!
}

// MARK: - Hero

@available(iOS 15.0, macOS 12.0, *)
private struct HeroSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DSWaveformImage")
                .font(.largeTitle.weight(.bold))
            Text("A tour of the rendering surface — pulse-modulated stereo demo audio throughout.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

// MARK: - Section primitive

@available(iOS 15.0, macOS 12.0, *)
private struct GallerySection<Content: View>: View {
    let title: String
    let systemImage: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, systemImage: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(title).font(.title2.weight(.semibold))
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(.tint)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
    }
}

// MARK: - Card primitive

@available(iOS 15.0, macOS 12.0, *)
private struct WaveformCard<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let caption {
                    Text(caption)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            content()
                .frame(maxWidth: .infinity)
        }
        .padding(WaveformGalleryStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WaveformGalleryStyle.cardCornerRadius, style: .continuous)
                .fill(WaveformGalleryStyle.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WaveformGalleryStyle.cardCornerRadius, style: .continuous)
                .strokeBorder(WaveformGalleryStyle.subtleStroke, lineWidth: 0.5)
        )
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

    @State private var renderer: RendererChoice = .linear
    @State private var style: StyleChoice = .gradient
    @State private var damped: Bool = true
    @State private var color: Color = .indigo

    var body: some View {
        GallerySection("Playground", systemImage: "slider.horizontal.3", subtitle: "Pick a renderer and a style — the same configuration drives the preview below.") {
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
            damping: damped ? .init(percentage: 0.125, sides: .both) : nil
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
        "\(renderer.rawValue) · \(style.rawValue.lowercased())\(damped ? " · damped" : "")"
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
