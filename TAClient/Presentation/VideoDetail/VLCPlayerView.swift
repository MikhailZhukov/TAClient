import SwiftUI
import MobileVLCKit
import OSLog

private let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "VLCPlayer")

struct VLCPlayerView: UIViewControllerRepresentable {
    let mediaURL: URL
    let startPosition: Double
    let duration: Double
    let onTimeChanged: (Double) -> Void
    @Binding var isFullScreen: Bool
    var sponsorBlockSeekTarget: Double?
    var seekDelta: Double?
    var onSeekDeltaConsumed: (() -> Void)?
    var onDoubleTap: ((_ forward: Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onTimeChanged: onTimeChanged, onDoubleTap: onDoubleTap)
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
        context.coordinator.onDoubleTap = onDoubleTap
        vc.doubleTapRecognizer?.isEnabled = onDoubleTap != nil
        if let target = sponsorBlockSeekTarget, vc.playerState.duration > 0 {
            let position = Float(target / vc.playerState.duration)
            vc.mediaPlayer?.position = min(max(position, 0), 1)
        }
        if let delta = seekDelta, vc.playerState.duration > 0 {
            let newTime = max(0, min(vc.playerState.duration, vc.playerState.currentTime + delta))
            let position = Float(newTime / vc.playerState.duration)
            vc.mediaPlayer?.position = min(max(position, 0), 1)
            DispatchQueue.main.async { onSeekDeltaConsumed?() }
        }
    }
}

// MARK: - Coordinator

extension VLCPlayerView {
    class Coordinator: NSObject, VLCMediaPlayerDelegate, UIGestureRecognizerDelegate {
        var onTimeChanged: (Double) -> Void
        var onDoubleTap: ((_ forward: Bool) -> Void)?
        weak var containerVC: VLCPlayerContainerVC?
        private var lastProgressReport: Date = .distantPast

        init(onTimeChanged: @escaping (Double) -> Void, onDoubleTap: ((_ forward: Bool) -> Void)? = nil) {
            self.onTimeChanged = onTimeChanged
            self.onDoubleTap = onDoubleTap
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            let forward = location.x >= view.bounds.width / 2
            onDoubleTap?(forward)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            guard let player = aNotification.object as? VLCMediaPlayer else { return }
            let seconds = Double(player.time.intValue) / 1000.0
            let totalDuration = Double(abs(player.remainingTime?.intValue ?? 0)) / 1000.0 + seconds

            Task { @MainActor in
                self.containerVC?.playerState.currentTime = seconds
                if totalDuration > 0 { self.containerVC?.playerState.duration = totalDuration }
            }

            if seconds > 0, Date().timeIntervalSince(lastProgressReport) >= 1 {
                lastProgressReport = Date()
                onTimeChanged(seconds)
            }
        }

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            guard let player = aNotification.object as? VLCMediaPlayer else { return }
            let state = player.state
            Task { @MainActor in
                self.containerVC?.playerState.isPlaying = player.isPlaying
                if state == .error {
                    logger.error("Player state: error, attempting restart")
                    self.containerVC?.restartMedia()
                } else if state == .ended {
                    self.containerVC?.exitFullScreenIfNeeded()
                }
            }
        }
    }
}

// MARK: - Container ViewController

class VLCPlayerContainerVC: UIViewController {
    let drawableView = UIView()
    let playerState: VLCPlayerState
    var mediaPlayer: VLCMediaPlayer?

    private let mediaURL: URL
    private let startPosition: Double
    private let initialDuration: Double
    private weak var coordinator: VLCPlayerView.Coordinator?

    fileprivate var controlsHost: UIHostingController<VLCPlayerControls>?
    fileprivate weak var doubleTapRecognizer: UITapGestureRecognizer?
    private var hideTimer: Timer?

    init(mediaURL: URL, startPosition: Double, duration: Double, coordinator: VLCPlayerView.Coordinator) {
        let state = VLCPlayerState()
        state.duration = duration
        self.playerState = state
        self.mediaURL = mediaURL
        self.startPosition = startPosition
        self.initialDuration = duration
        self.coordinator = coordinator
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
        setupDoubleTapRecognizer()
    }

    private func setupDoubleTapRecognizer() {
        guard let coordinator else { return }
        let tap = UITapGestureRecognizer(
            target: coordinator,
            action: #selector(VLCPlayerView.Coordinator.handleDoubleTap(_:))
        )
        tap.numberOfTapsRequired = 2
        tap.cancelsTouchesInView = false
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
        self.doubleTapRecognizer = tap
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

    func restartMedia() {
        let resumePosition = playerState.currentTime
        mediaPlayer?.stop()

        let media = VLCMedia(url: mediaURL)
        media.addOptions(["network-caching": 3000])
        mediaPlayer?.media = media
        mediaPlayer?.play()

        if resumePosition > 0, playerState.duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let player = self.mediaPlayer else { return }
                let position = Float(resumePosition / self.playerState.duration)
                player.position = min(max(position, 0), 1)
            }
        }
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
        let controls = VLCPlayerControls(
            state: playerState,
            onPlayPause: { [weak self] in self?.togglePlayPause() },
            onSeek: { [weak self] seconds in self?.seek(to: seconds) },
            onToggleFullScreen: { [weak self] in self?.toggleFullScreen() },
            onTapToggle: { [weak self] in self?.handleTap() }
        )
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

    func exitFullScreenIfNeeded() {
        if let presented = presentedViewController as? VLCFullScreenVC {
            presented.dismiss(animated: true)
        }
    }

    // MARK: - Actions

    private func togglePlayPause() {
        guard let player = mediaPlayer else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        scheduleHideControls()
    }

    private func seek(to seconds: Double) {
        guard let player = mediaPlayer, playerState.duration > 0 else { return }
        let position = Float(seconds / playerState.duration)
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
        playerState.controlsVisible.toggle()
        if playerState.controlsVisible {
            scheduleHideControls()
        } else {
            hideTimer?.invalidate()
        }
    }

    private func scheduleHideControls() {
        hideTimer?.invalidate()
        playerState.controlsVisible = true
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.playerState.controlsVisible = false
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
