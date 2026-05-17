import DSWaveformImage
import SwiftUI

@available(iOS 15.0, macOS 12.0, *)
/// Renders and displays a waveform for the audio at `audioURL`.
public struct WaveformView<Content: View>: View {
    private let audioURL: URL
    private let configuration: Waveform.Configuration
    private let renderer: WaveformRenderer
    private let priority: TaskPriority
    private let content: (WaveformShape) -> Content

    @State private var samples: [Float] = []
    @State private var spectralCentroids: [Float] = []
    @State private var rescaleTimer: Timer?
    @State private var currentSize: CGSize = .zero

    /**
     Creates a new WaveformView which displays a waveform for the audio at `audioURL`.

     - Parameters:
        - audioURL: The `URL` of the audio asset to be rendered.
        - configuration: The `Waveform.Configuration` to be used for rendering.
        - renderer: The `WaveformRenderer` implementation to be used. Defaults to `LinearWaveformRenderer`. Also comes with `CircularWaveformRenderer`.
        - priority: The `TaskPriority` used during analyzing. Defaults to `.userInitiated`.
        - content: ViewBuilder with the WaveformShape to be customized.
     */
    public init(
        audioURL: URL,
        configuration: Waveform.Configuration = Waveform.Configuration(damping: .init(percentage: 0.125, sides: .both)),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        priority: TaskPriority = .userInitiated,
        @ViewBuilder content: @escaping (WaveformShape) -> Content
    ) {
        self.audioURL = audioURL
        self.configuration = configuration
        self.renderer = renderer
        self.priority = priority
        self.content = content
    }

    public var body: some View {
        GeometryReader { geometry in
            Group {
                if case .spectralTint = configuration.style {
                    // Spectral tint can't be expressed as a single Path/fill, so it bypasses the
                    // `WaveformShape`+`content` pipeline and renders per-column into a Canvas via the
                    // shared `WaveformImageDrawer`. Custom `content` closures don't apply in this mode
                    // — the tinting drives the visual style end-to-end.
                    spectralCanvas
                } else {
                    content(WaveformShape(samples: samples, configuration: configuration, renderer: renderer))
                }
            }
                .scaleEffect(x: scaleDuringResize(for: geometry), y: 1, anchor: resizeAnchor)
                .onAppear {
                    guard samples.isEmpty else { return }
                    update(size: geometry.size, url: audioURL, configuration: configuration)
                }
                .modifier(OnChange(of: geometry.size, action: { newValue in update(size: newValue, url: audioURL, configuration: configuration, delayed: true) }))
                .modifier(OnChange(of: audioURL, action: { newValue in update(size: geometry.size, url: audioURL, configuration: configuration) }))
                .modifier(OnChange(of: configuration, action: { newValue in update(size: geometry.size, url: audioURL, configuration: newValue) }))
        }
    }

    @ViewBuilder
    private var spectralCanvas: some View {
        let samples = self.samples
        let centroids = self.spectralCentroids
        let configuration = self.configuration
        let renderer = self.renderer
        Canvas(rendersAsynchronously: true) { context, size in
            context.withCGContext { cgContext in
                let effectiveRenderer = (renderer as? SpectralAwareWaveformRenderer)?.withSpectralCentroids(centroids) ?? renderer
                WaveformImageDrawer().draw(waveform: samples, on: cgContext, with: configuration.with(size: size), renderer: effectiveRenderer)
            }
        }
    }

    private func update(size: CGSize, url: URL, configuration: Waveform.Configuration, delayed: Bool = false) {
        rescaleTimer?.invalidate()

        let updateTask: @Sendable (Timer?) -> Void = { _ in
            Task(priority: .userInitiated) {
                do {
                    let samplesNeeded = Int(size.width * configuration.scale)
                    let channelSelection = (renderer as? ChannelAwareWaveformRenderer)?.channelSelection ?? .merged

                    if case .spectralTint = configuration.style {
                        let analysis = try await WaveformAnalyzer().analyze(fromAudioAt: url, count: samplesNeeded, channelSelection: channelSelection)
                        await MainActor.run {
                            self.currentSize = size
                            self.samples = analysis.amplitudes
                            self.spectralCentroids = analysis.spectralCentroids
                        }
                    } else {
                        let samples = try await WaveformAnalyzer().samples(fromAudioAt: url, count: samplesNeeded, channelSelection: channelSelection)
                        await MainActor.run {
                            self.currentSize = size
                            self.samples = samples
                        }
                    }
                } catch {
                    assertionFailure(error.localizedDescription)
                }
            }
        }

        if delayed {
            rescaleTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false, block: updateTask)
            RunLoop.main.add(rescaleTimer!, forMode: .common)
        } else {
            updateTask(nil)
        }
    }

    /*
     * During resizing, we only visually scale the previously-rendered shape to make it look seamless,
     * before re-sampling the waveform for the new size (which is costly). The horizontal scale is
     * derived from the ratio of the new width to the width the current samples were computed for.
     * The anchor depends on the renderer: linear-style renderers offset the path to the right when
     * `samples.count != samplesNeeded`, so the right edge is the stable reference. Circular renderers
     * are centered, so x-only scaling would distort the circle and is skipped — the Shape re-evaluates
     * with the new size each layout pass, which keeps the circle reasonable until re-sampling lands.
     */
    private func scaleDuringResize(for geometry: GeometryProxy) -> CGFloat {
        guard currentSize.width > 0, !(renderer is CircularWaveformRenderer) else { return 1 }
        return geometry.size.width / currentSize.width
    }

    private var resizeAnchor: UnitPoint {
        renderer is CircularWaveformRenderer ? .center : .trailing
    }
}

public extension WaveformView {
    /**
     Creates a new WaveformView which displays a waveform for the audio at `audioURL`.

     - Parameters:
        - audioURL: The `URL` of the audio asset to be rendered.
        - configuration: The `Waveform.Configuration` to be used for rendering.
        - renderer: The `WaveformRenderer` implementation to be used. Defaults to `LinearWaveformRenderer`. Also comes with `CircularWaveformRenderer`.
        - priority: The `TaskPriority` used during analyzing. Defaults to `.userInitiated`.
     */
    init(
        audioURL: URL,
        configuration: Waveform.Configuration = Waveform.Configuration(damping: .init(percentage: 0.125, sides: .both)),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        priority: TaskPriority = .userInitiated
    ) where Content == AnyView {
        self.init(audioURL: audioURL, configuration: configuration, renderer: renderer, priority: priority) { shape in
            AnyView(DefaultShapeStyler().style(shape: shape, with: configuration))
        }
    }

    /**
     Creates a new WaveformView which displays a waveform for the audio at `audioURL`.

     - Parameters:
        - audioURL: The `URL` of the audio asset to be rendered.
        - configuration: The `Waveform.Configuration` to be used for rendering.
        - renderer: The `WaveformRenderer` implementation to be used. Defaults to `LinearWaveformRenderer`. Also comes with `CircularWaveformRenderer`.
        - priority: The `TaskPriority` used during analyzing. Defaults to `.userInitiated`.
        - placeholder: ViewBuilder for a placeholder view during the loading phase.
     */
    init<Placeholder: View>(
        audioURL: URL,
        configuration: Waveform.Configuration = Waveform.Configuration(damping: .init(percentage: 0.125, sides: .both)),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        priority: TaskPriority = .userInitiated,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Content == _ConditionalContent<Placeholder, AnyView> {
        self.init(audioURL: audioURL, configuration: configuration, renderer: renderer, priority: priority) { shape in
            if shape.isEmpty {
                placeholder()
            } else {
                AnyView(DefaultShapeStyler().style(shape: shape, with: configuration))
            }
        }
    }

    /**
     Creates a new WaveformView which displays a waveform for the audio at `audioURL`.

     - Parameters:
        - audioURL: The `URL` of the audio asset to be rendered.
        - configuration: The `Waveform.Configuration` to be used for rendering.
        - renderer: The `WaveformRenderer` implementation to be used. Defaults to `LinearWaveformRenderer`. Also comes with `CircularWaveformRenderer`.
        - priority: The `TaskPriority` used during analyzing. Defaults to `.userInitiated`.
        - content: ViewBuilder with the WaveformShape to be customized.
        - placeholder: ViewBuilder for a placeholder view during the loading phase.
     */
    init<Placeholder: View, ModifiedContent: View>(
        audioURL: URL,
        configuration: Waveform.Configuration = Waveform.Configuration(damping: .init(percentage: 0.125, sides: .both)),
        renderer: WaveformRenderer = LinearWaveformRenderer(),
        priority: TaskPriority = .userInitiated,
        @ViewBuilder content: @escaping (WaveformShape) -> ModifiedContent,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Content == _ConditionalContent<Placeholder, ModifiedContent> {
        self.init(audioURL: audioURL, configuration: configuration, renderer: renderer, priority: priority) { shape in
            if shape.isEmpty {
                placeholder()
            } else {
                content(shape)
            }
        }
    }
}
