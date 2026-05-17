import SwiftUI

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
enum SampleAudio {
    /// Synthetic 6-second stereo clip: both channels carry continuously FM-modulated carriers with
    /// independent multi-LFO amplitude envelopes — L and R have visibly different shapes, the
    /// envelope is "random looking" without silent gaps, and there's content right up to the end.
    /// The gallery uses this single asset for every showcase.
    static let stereoDemo: URL = Bundle.main.url(forResource: "example_stereo", withExtension: "m4a")!
}

// MARK: - Hero header

@available(iOS 15.0, macOS 12.0, *)
struct GalleryHero: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

// MARK: - Section primitive

@available(iOS 15.0, macOS 12.0, *)
struct GallerySection<Content: View>: View {
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
struct WaveformCard<Content: View>: View {
    let title: String?
    let caption: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String? = nil, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || caption != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        Text(title).font(.subheadline.weight(.semibold))
                    }
                    if let caption {
                        Text(caption)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
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

// MARK: - Scroll container

/// Shared scroll layout used by every showcase: centered, capped at a comfortable reading width,
/// LazyVStack so off-screen sections defer their work (matters for sections that kick off audio
/// analysis on appear).
@available(iOS 15.0, macOS 12.0, *)
struct GalleryScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LazyVStack(alignment: .leading, spacing: 28) {
                    content()
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
