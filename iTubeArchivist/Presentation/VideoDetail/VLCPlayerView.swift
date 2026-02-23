import SwiftUI
import MobileVLCKit

struct VLCPlayerView: UIViewControllerRepresentable {
    let mediaURL: URL
    let startPosition: Double
    let duration: Double
    let onTimeChanged: (Double) -> Void
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onTimeChanged: onTimeChanged)
    }

    func makeUIViewController(context: Context) -> VLCPlayerContainerVC {
        let vc = VLCPlayerContainerVC(
            mediaURL: mediaURL,
            startPosition: startPosition,
            duration: duration,
            coordinator: context.coordinator
        )
        context.coordinator.containerVC = vc
        return vc
    }

    func updateUIViewController(_ vc: VLCPlayerContainerVC, context: Context) {
        context.coordinator.onTimeChanged = onTimeChanged
    }
}

// MARK: - Coordinator

extension VLCPlayerView {
    class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var onTimeChanged: (Double) -> Void
        weak var containerVC: VLCPlayerContainerVC?
        private var lastProgressReport: Date = .distantPast

        init(onTimeChanged: @escaping (Double) -> Void) {
            self.onTimeChanged = onTimeChanged
        }

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            guard let player = aNotification.object as? VLCMediaPlayer else { return }
            let seconds = Double(player.time.intValue) / 1000.0
            let totalDuration = Double(abs(player.remainingTime?.intValue ?? 0)) / 1000.0 + seconds

            Task { @MainActor in
                self.containerVC?.updateTime(current: seconds, duration: totalDuration)
            }

            if Date().timeIntervalSince(lastProgressReport) >= 10 {
                lastProgressReport = Date()
                if seconds > 0 {
                    onTimeChanged(seconds)
                }
            }
        }

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            guard let player = aNotification.object as? VLCMediaPlayer else { return }
            Task { @MainActor in
                self.containerVC?.updatePlayingState(player.isPlaying)
            }
        }
    }
}

// MARK: - Container ViewController

class VLCPlayerContainerVC: UIViewController {
    let drawableView = UIView()
    var mediaPlayer: VLCMediaPlayer?

    private let mediaURL: URL
    private let startPosition: Double
    private let initialDuration: Double
    private weak var coordinator: VLCPlayerView.Coordinator?

    fileprivate var controlsHost: UIHostingController<VLCPlayerControls>?
    private var controlsVisible = true
    private var hideTimer: Timer?
    private var currentTime: Double = 0
    private var currentDuration: Double = 0
    private var isMediaPlaying = false

    init(mediaURL: URL, startPosition: Double, duration: Double, coordinator: VLCPlayerView.Coordinator) {
        self.mediaURL = mediaURL
        self.startPosition = startPosition
        self.initialDuration = duration
        self.coordinator = coordinator
        self.currentDuration = duration
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupDrawable()
        setupControls()
        setupPlayer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            cleanup()
        }
    }

    func cleanup() {
        hideTimer?.invalidate()
        hideTimer = nil
        mediaPlayer?.stop()
        mediaPlayer = nil
    }

    // MARK: - Setup

    private func setupDrawable() {
        drawableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawableView)
        NSLayoutConstraint.activate([
            drawableView.topAnchor.constraint(equalTo: view.topAnchor),
            drawableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            drawableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupPlayer() {
        let media = VLCMedia(url: mediaURL)
        media.addOptions(["network-caching": 3000])

        let player = VLCMediaPlayer()
        player.delegate = coordinator
        player.drawable = drawableView
        player.media = media
        self.mediaPlayer = player
        player.play()

        if startPosition > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let player = self.mediaPlayer else { return }
                let position = Float(self.startPosition / max(self.initialDuration, 1))
                player.position = min(max(position, 0), 1)
            }
        }

        scheduleHideControls()
    }

    // MARK: - Controls

    private func setupControls() {
        let controls = makeControls()
        let host = UIHostingController(rootView: controls)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        host.didMove(toParent: self)
        controlsHost = host
    }

    private func makeControls() -> VLCPlayerControls {
        VLCPlayerControls(
            isPlaying: isMediaPlaying,
            currentTime: currentTime,
            duration: currentDuration,
            visible: controlsVisible,
            onPlayPause: { [weak self] in self?.togglePlayPause() },
            onSeek: { [weak self] seconds in self?.seek(to: seconds) },
            onToggleFullScreen: { [weak self] in self?.toggleFullScreen() },
            onTapToggle: { [weak self] in self?.handleTap() }
        )
    }

    private func refreshControls() {
        controlsHost?.rootView = makeControls()
    }

    func updateTime(current: Double, duration: Double) {
        currentTime = current
        if duration > 0 { currentDuration = duration }
        refreshControls()
    }

    func updatePlayingState(_ playing: Bool) {
        isMediaPlaying = playing
        refreshControls()
    }

    // MARK: - Actions

    private func togglePlayPause() {
        guard let player = mediaPlayer else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        scheduleHideControls()
    }

    private func seek(to seconds: Double) {
        guard let player = mediaPlayer, currentDuration > 0 else { return }
        let position = Float(seconds / currentDuration)
        player.position = min(max(position, 0), 1)
        scheduleHideControls()
    }

    private func toggleFullScreen() {
        if let presented = presentedViewController as? VLCFullScreenVC {
            presented.dismiss(animated: true)
        } else {
            let fullScreenVC = VLCFullScreenVC(containerVC: self)
            fullScreenVC.modalPresentationStyle = .fullScreen
            present(fullScreenVC, animated: true)
        }
    }

    func reparentDrawable(to targetView: UIView) {
        drawableView.removeFromSuperview()
        drawableView.translatesAutoresizingMaskIntoConstraints = false
        targetView.insertSubview(drawableView, at: 0)
        NSLayoutConstraint.activate([
            drawableView.topAnchor.constraint(equalTo: targetView.topAnchor),
            drawableView.bottomAnchor.constraint(equalTo: targetView.bottomAnchor),
            drawableView.leadingAnchor.constraint(equalTo: targetView.leadingAnchor),
            drawableView.trailingAnchor.constraint(equalTo: targetView.trailingAnchor),
        ])
        mediaPlayer?.drawable = drawableView
    }

    private func handleTap() {
        controlsVisible.toggle()
        if controlsVisible {
            scheduleHideControls()
        } else {
            hideTimer?.invalidate()
        }
        refreshControls()
    }

    private func scheduleHideControls() {
        hideTimer?.invalidate()
        controlsVisible = true
        refreshControls()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.controlsVisible = false
            self.refreshControls()
        }
    }
}

// MARK: - Full Screen ViewController

private class VLCFullScreenVC: UIViewController {
    private weak var containerVC: VLCPlayerContainerVC?

    init(containerVC: VLCPlayerContainerVC) {
        self.containerVC = containerVC
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        containerVC?.reparentDrawable(to: view)
        reparentControls(to: view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let containerVC else { return }
        containerVC.reparentDrawable(to: containerVC.view)
        reparentControls(to: containerVC.view)
    }

    private func reparentControls(to targetView: UIView) {
        guard let controlsView = containerVC?.controlsHost?.view else { return }
        controlsView.removeFromSuperview()
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        targetView.addSubview(controlsView)
        let guide = targetView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            controlsView.topAnchor.constraint(equalTo: guide.topAnchor),
            controlsView.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            controlsView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
    }
}
