import UIKit
import DSWaveformImage
import DSWaveformImageViews

/// Modernized, card-based UIKit showcase. Mirrors the visual language of the SwiftUI gallery so
/// the two reference implementations feel like siblings, while staying entirely UIKit.
final class UIKitShowcaseViewController: UIViewController {
    private let waveformImageDrawer = WaveformImageDrawer()
    private let audioManager = SCAudioManager()
    private let audioURL = Bundle.main.url(forResource: "example_stereo", withExtension: "m4a")!

    // Static section
    private let circularStaticView = UIImageView()
    private let linearStaticView = WaveformImageView(frame: .zero)
    private let blendedStaticView = UIImageView()
    private let blendedBackgroundView = UIImageView()

    // Live recording
    private let liveWaveformView = WaveformLiveView(frame: .zero)
    private let recordButton = UIButton(type: .system)

    // Progress
    private let progressBaseImageView = UIImageView()
    private let progressOverlayImageView = UIImageView()
    private var progress: Double = 0.4

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "UIKit"
        setupLayout()
        audioManager.recordingDelegate = self
        audioManager.prepareAudioRecording()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        renderStaticImages()
        renderProgressImages()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateProgressMask()
    }

    // MARK: - Layout

    private func setupLayout() {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        let contentStack = UIStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 28
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)

        contentStack.addArrangedSubview(makeHero())
        contentStack.addArrangedSubview(makeStaticSection())
        contentStack.addArrangedSubview(makeLiveRecordingSection())
        contentStack.addArrangedSubview(makeProgressSection())

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    private func makeHero() -> UIView {
        let title = UILabel()
        title.text = "DSWaveformImage"
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.numberOfLines = 0

        let subtitle = UILabel()
        subtitle.text = "Same library, pure UIKit composition — drawers, views, and live capture."
        subtitle.font = .preferredFont(forTextStyle: .callout)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [title, subtitle])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    private func makeStaticSection() -> UIView {
        let header = makeSectionHeader(
            title: "Static rendering",
            systemImage: "waveform",
            subtitle: "Drop a Configuration and a renderer into WaveformImageDrawer — same audio, three looks."
        )

        circularStaticView.contentMode = .scaleToFill
        let circular = makeCard(
            title: "Circular · gradient damping",
            caption: "CircularWaveformRenderer() + .gradient([…])",
            content: aspectRatio(circularStaticView, 1)
        )

        linearStaticView.contentMode = .scaleToFill
        let linear = makeCard(
            title: "Linear · striped",
            caption: "WaveformImageView with .striped(.init(color: …))",
            content: aspectRatio(linearStaticView, 16.0/9.0)
        )

        blendedBackgroundView.image = UIImage(named: "background")
        blendedBackgroundView.contentMode = .scaleAspectFill
        blendedBackgroundView.clipsToBounds = true
        blendedStaticView.contentMode = .scaleToFill
        blendedStaticView.layer.compositingFilter = "overlayBlendMode"

        let blendContainer = UIView()
        blendContainer.translatesAutoresizingMaskIntoConstraints = false
        blendContainer.clipsToBounds = true
        blendContainer.layer.cornerRadius = 10
        blendContainer.layer.cornerCurve = .continuous
        [blendedBackgroundView, blendedStaticView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            blendContainer.addSubview($0)
        }
        NSLayoutConstraint.activate([
            blendedBackgroundView.topAnchor.constraint(equalTo: blendContainer.topAnchor),
            blendedBackgroundView.leadingAnchor.constraint(equalTo: blendContainer.leadingAnchor),
            blendedBackgroundView.trailingAnchor.constraint(equalTo: blendContainer.trailingAnchor),
            blendedBackgroundView.bottomAnchor.constraint(equalTo: blendContainer.bottomAnchor),

            blendedStaticView.topAnchor.constraint(equalTo: blendContainer.topAnchor),
            blendedStaticView.leadingAnchor.constraint(equalTo: blendContainer.leadingAnchor),
            blendedStaticView.trailingAnchor.constraint(equalTo: blendContainer.trailingAnchor),
            blendedStaticView.bottomAnchor.constraint(equalTo: blendContainer.bottomAnchor),
            blendContainer.heightAnchor.constraint(equalTo: blendContainer.widthAnchor, multiplier: 9.0/16.0)
        ])
        let blended = makeCard(
            title: "Composited on backdrop",
            caption: "layer.compositingFilter = \"overlayBlendMode\"",
            content: blendContainer
        )

        return makeSection(header: header, cards: [circular, linear, blended])
    }

    private func makeLiveRecordingSection() -> UIView {
        let header = makeSectionHeader(
            title: "Live recording",
            systemImage: "mic.circle",
            subtitle: "WaveformLiveView ingests microphone samples — the heavy lifting is one .add(samples:) call."
        )

        liveWaveformView.configuration = .init(
            style: .striped(.init(color: .systemIndigo, width: 3, spacing: 3)),
            damping: .init(percentage: 0.125, sides: .both)
        )
        liveWaveformView.translatesAutoresizingMaskIntoConstraints = false
        liveWaveformView.backgroundColor = .clear
        liveWaveformView.heightAnchor.constraint(equalToConstant: 120).isActive = true

        var buttonConfig = UIButton.Configuration.borderedProminent()
        buttonConfig.title = "Start Recording"
        buttonConfig.image = UIImage(systemName: "record.circle")
        buttonConfig.imagePadding = 6
        buttonConfig.baseBackgroundColor = .systemRed
        recordButton.configuration = buttonConfig
        recordButton.addTarget(self, action: #selector(didTapRecording), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [liveWaveformView, recordButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center

        // Stretch the waveform full width inside the card's content column.
        liveWaveformView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        liveWaveformView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return makeSection(
            header: header,
            cards: [makeCard(
                title: nil,
                caption: "WaveformLiveView().add(samples: [Float])",
                content: stack
            )]
        )
    }

    private func makeProgressSection() -> UIView {
        let header = makeSectionHeader(
            title: "Progress",
            systemImage: "play.circle.fill",
            subtitle: "Render the waveform once, then mask a tinted copy with a layer mask that tracks playback."
        )

        let stackedView = UIView()
        stackedView.translatesAutoresizingMaskIntoConstraints = false
        [progressBaseImageView, progressOverlayImageView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.contentMode = .scaleAspectFit
            stackedView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            progressBaseImageView.topAnchor.constraint(equalTo: stackedView.topAnchor),
            progressBaseImageView.leadingAnchor.constraint(equalTo: stackedView.leadingAnchor),
            progressBaseImageView.trailingAnchor.constraint(equalTo: stackedView.trailingAnchor),
            progressBaseImageView.bottomAnchor.constraint(equalTo: stackedView.bottomAnchor),

            progressOverlayImageView.topAnchor.constraint(equalTo: stackedView.topAnchor),
            progressOverlayImageView.leadingAnchor.constraint(equalTo: stackedView.leadingAnchor),
            progressOverlayImageView.trailingAnchor.constraint(equalTo: stackedView.trailingAnchor),
            progressOverlayImageView.bottomAnchor.constraint(equalTo: stackedView.bottomAnchor),
            stackedView.heightAnchor.constraint(equalToConstant: 110)
        ])

        var shuffleConfig = UIButton.Configuration.tinted()
        shuffleConfig.title = "Shuffle progress"
        shuffleConfig.image = UIImage(systemName: "dice.fill")
        shuffleConfig.imagePadding = 6
        let shuffleButton = UIButton(configuration: shuffleConfig, primaryAction: UIAction { [weak self] _ in
            self?.shuffleProgress()
        })

        let stack = UIStackView(arrangedSubviews: [stackedView, shuffleButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stackedView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return makeSection(
            header: header,
            cards: [makeCard(
                title: nil,
                caption: "imageView.layer.mask = CAShapeLayer(rect: …, width: w * progress)",
                content: stack
            )]
        )
    }

    // MARK: - Card / Section primitives

    private func makeSection(header: UIView, cards: [UIView]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [header] + cards)
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        return stack
    }

    private func makeSectionHeader(title: String, systemImage: String, subtitle: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.tintColor = .tintColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.numberOfLines = 0

        let titleRow = UIStackView(arrangedSubviews: [icon, titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .callout)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .fill
        stack.setCustomSpacing(2, after: titleRow)
        return stack
    }

    private func makeCard(title: String?, caption: String?, content: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.systemGray.withAlphaComponent(0.3).cgColor

        let inner = UIStackView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.axis = .vertical
        inner.spacing = 12
        inner.alignment = .fill

        if title != nil || caption != nil {
            let header = UIStackView()
            header.axis = .vertical
            header.spacing = 2
            header.alignment = .leading

            if let title {
                let titleLabel = UILabel()
                titleLabel.text = title
                titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
                titleLabel.numberOfLines = 0
                header.addArrangedSubview(titleLabel)
            }
            if let caption {
                let captionLabel = UILabel()
                captionLabel.text = caption
                captionLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                captionLabel.textColor = .secondaryLabel
                captionLabel.numberOfLines = 0
                header.addArrangedSubview(captionLabel)
            }
            inner.addArrangedSubview(header)
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(content)

        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    private func aspectRatio(_ view: UIView, _ ratio: CGFloat) -> UIView {
        let wrapper = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            wrapper.heightAnchor.constraint(equalTo: wrapper.widthAnchor, multiplier: 1.0 / ratio)
        ])
        return wrapper
    }

    // MARK: - Static rendering

    private func renderStaticImages() {
        guard circularStaticView.bounds.size != .zero else { return }
        renderCircularStatic()
        renderBlendedStatic()
        renderLinearStatic()
    }

    private func renderCircularStatic() {
        Task {
            let image = try? await waveformImageDrawer.waveformImage(
                fromAudioAt: audioURL,
                with: .init(
                    size: circularStaticView.bounds.size,
                    style: .gradient([
                        UIColor(red: 255/255, green: 159/255, blue: 28/255, alpha: 1),
                        UIColor(red: 255/255, green: 191/255, blue: 105/255, alpha: 1),
                        .red
                    ]),
                    damping: .init(percentage: 0.2, sides: .right, easing: { x in pow(x, 4) })
                ),
                renderer: CircularWaveformRenderer()
            )
            await MainActor.run { self.circularStaticView.image = image }
        }
    }

    private func renderLinearStatic() {
        linearStaticView.configuration = .init(
            backgroundColor: .clear,
            style: .striped(.init(color: UIColor(red: 51/255, green: 92/255, blue: 103/255, alpha: 1), width: 5, spacing: 5)),
            verticalScalingFactor: 0.5
        )
        linearStaticView.waveformAudioURL = audioURL
    }

    private func renderBlendedStatic() {
        Task {
            let image = try? await waveformImageDrawer.waveformImage(
                fromAudioAt: audioURL,
                with: .init(size: blendedStaticView.bounds.size, style: .filled(.black)),
                position: .top
            )
            await MainActor.run { self.blendedStaticView.image = image }
        }
    }

    // MARK: - Live recording

    @objc private func didTapRecording() {
        if audioManager.recording() {
            audioManager.stopRecording()
        } else {
            liveWaveformView.reset()
            audioManager.startRecording()
        }
        updateRecordButtonTitle()
    }

    private func updateRecordButtonTitle() {
        var config = recordButton.configuration
        let isRecording = audioManager.recording()
        config?.title = isRecording ? "Stop Recording" : "Start Recording"
        config?.image = UIImage(systemName: isRecording ? "stop.circle.fill" : "record.circle")
        recordButton.configuration = config
    }

    // MARK: - Progress

    private func renderProgressImages() {
        guard progressBaseImageView.bounds.size != .zero else { return }
        Task {
            let image = try? await waveformImageDrawer.waveformImage(
                fromAudioAt: audioURL,
                with: .init(size: progressBaseImageView.bounds.size, style: .filled(.systemGray3))
            )
            await MainActor.run {
                self.progressBaseImageView.image = image
                self.progressOverlayImageView.image = image?.withTintColor(.systemIndigo, renderingMode: .alwaysTemplate)
                self.updateProgressMask()
            }
        }
    }

    private func shuffleProgress() {
        progress = .random(in: 0...1)
        updateProgressMask()
    }

    private func updateProgressMask() {
        let bounds = progressOverlayImageView.bounds
        guard bounds.width > 0 else { return }
        let maskLayer = CAShapeLayer()
        maskLayer.path = CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width * progress, height: bounds.height), transform: nil)
        progressOverlayImageView.layer.mask = maskLayer
    }
}

extension UIKitShowcaseViewController: RecordingDelegate {
    func audioManager(_ manager: SCAudioManager!, didAllowRecording success: Bool) {
        if !success {
            preconditionFailure("Recording must be allowed in Settings to work.")
        }
    }

    func audioManager(_ manager: SCAudioManager!, didFinishRecordingSuccessfully success: Bool) {
        updateRecordButtonTitle()
    }

    func audioManager(_ manager: SCAudioManager!, didUpdateRecordProgress progress: CGFloat) {
        let linear = 1 - pow(10, manager.lastAveragePower() / 20)
        liveWaveformView.add(samples: [Float(linear), Float(linear), Float(linear)])
    }
}
