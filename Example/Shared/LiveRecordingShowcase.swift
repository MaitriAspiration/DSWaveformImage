import DSWaveformImage
import DSWaveformImageViews
import SwiftUI

// MARK: - Recorder abstraction

/// Minimal interface a per-platform recorder has to expose to power the shared SwiftUI showcase.
/// The view doesn't care how samples are produced — that's the responsibility of the concrete
/// recorder for each platform (e.g. SCAudioManager on iOS).
@available(iOS 15.0, macOS 12.0, *)
@MainActor
public protocol AudioRecording: ObservableObject {
    var samples: [Float] { get }
    var recordingTime: TimeInterval { get }
    var isRecording: Bool { get set }
}

// MARK: - Showcase

/// Modernized SwiftUI live-recording demo. Shared across platforms — supply a recorder
/// implementation appropriate for the host platform.
@available(iOS 15.0, macOS 12.0, *)
public struct LiveRecordingShowcase<Recorder: AudioRecording>: View {
    @ObservedObject private var recorder: Recorder

    public init(recorder: Recorder) {
        self.recorder = recorder
    }

    public var body: some View {
        GalleryScrollView {
            GalleryHero(
                title: "Live Recording",
                subtitle: "Stream microphone amplitude into WaveformLiveCanvas — change renderer, style, and damping live."
            )
            CircularPreviewSection(recorder: recorder)
            TimelineSection(recorder: recorder)
            ControlsAndIndicatorSection(recorder: recorder)
        }
    }
}

// MARK: - Sections

@available(iOS 15.0, macOS 12.0, *)
private struct CircularPreviewSection<Recorder: AudioRecording>: View {
    @ObservedObject var recorder: Recorder
    @State private var padSilence: Bool = true

    var body: some View {
        GallerySection(
            "Circular renderer",
            systemImage: "circle.dashed",
            subtitle: "WaveformLiveCanvas drives CircularWaveformRenderer with the latest sample buffer."
        ) {
            WaveformCard(caption: "WaveformLiveCanvas(samples: …, renderer: CircularWaveformRenderer(kind: .circle))") {
                VStack(spacing: 14) {
                    WaveformLiveCanvas(
                        samples: recorder.samples,
                        configuration: .init(style: .striped(.init(color: .systemIndigo, width: 3, spacing: 3))),
                        renderer: CircularWaveformRenderer(kind: .circle),
                        shouldDrawSilencePadding: padSilence
                    )
                    .frame(height: 240)

                    Toggle("Pad silence", isOn: $padSilence)
                        .toggleStyle(.switch)
                        .font(.subheadline)
                }
            }
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct TimelineSection<Recorder: AudioRecording>: View {
    @ObservedObject var recorder: Recorder

    private enum StyleChoice: String, CaseIterable, Identifiable {
        case filled = "Filled"
        case gradient = "Gradient"
        case striped = "Striped"
        var id: Self { self }
    }

    @State private var style: StyleChoice = .gradient

    private var configuration: Waveform.Configuration {
        switch style {
        case .filled:
            return .init(style: .filled(.systemRed), damping: .init(percentage: 0.125, sides: .both))
        case .gradient:
            return .init(style: .gradient([.systemBlue, .systemPurple]), damping: .init(percentage: 0.125, sides: .both))
        case .striped:
            return .init(style: .striped(.init(color: .systemTeal, width: 3, spacing: 3)), damping: .init(percentage: 0.125, sides: .both))
        }
    }

    var body: some View {
        GallerySection(
            "Timeline",
            systemImage: "waveform.path",
            subtitle: "Linear renderer with damped edges — switch style to compare how the same envelope reads."
        ) {
            WaveformCard {
                VStack(spacing: 14) {
                    WaveformLiveCanvas(samples: recorder.samples, configuration: configuration)
                        .frame(height: 160)

                    Picker("Style", selection: $style) {
                        ForEach(StyleChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct ControlsAndIndicatorSection<Recorder: AudioRecording>: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        GallerySection(
            "Compact indicator",
            systemImage: "record.circle",
            subtitle: "A drop-in mic widget — tap the circle to start, drag and embed anywhere."
        ) {
            WaveformCard {
                CompactRecordingIndicator(
                    samples: recorder.samples,
                    duration: recorder.recordingTime,
                    isRecording: Binding(
                        get: { recorder.isRecording },
                        set: { recorder.isRecording = $0 }
                    )
                )
            }
        }
    }
}

// MARK: - Compact indicator widget

@available(iOS 15.0, macOS 12.0, *)
private struct CompactRecordingIndicator: View {
    let samples: [Float]
    let duration: TimeInterval
    @Binding var isRecording: Bool

    private static let timeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.minute, .second]
        f.zeroFormattingBehavior = .pad
        return f
    }()

    private static let configuration = Waveform.Configuration(
        style: .striped(.init(color: .systemGray, width: 3, spacing: 3)),
        damping: .init()
    )

    var body: some View {
        HStack(spacing: 12) {
            WaveformLiveCanvas(samples: samples, configuration: Self.configuration)
                .padding(.vertical, 2)

            Text(Self.timeFormatter.string(from: duration) ?? "00:00")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Button {
                isRecording.toggle()
            } label: {
                Image(systemName: isRecording ? "stop.circle" : "record.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 36)
    }
}
