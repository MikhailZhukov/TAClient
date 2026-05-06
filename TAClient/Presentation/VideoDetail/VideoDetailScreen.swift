import SwiftUI

/// Thin wrapper view that owns a `VideoDetailViewModel` via `@State` so the VM
/// is constructed exactly once per `NavigationStack` push (and torn down once
/// per pop).
///
/// Without this wrapper, every `navigationDestination` body re-evaluation in
/// `TAClientApp` would call `container.makeVideoDetailViewModel(...)` inline,
/// creating a new VM (and a new `AVPlayer`, observers, preloader, etc.) on
/// every parent body re-render. SwiftUI keeps the previous VM alive as long as
/// it holds a reference, so multiple parallel VMs accumulate — the root cause
/// of the duplicate `Buffer underrun` log lines and parallel byte-range fetches
/// observed in production.
struct VideoDetailScreen: View {
    // INVARIANT: VideoDetailViewModel.init must remain side-effect-free.
    // SwiftUI evaluates the `make` closure on every parent body re-eval; only the
    // FIRST result becomes @State storage, the rest are immediately discarded.
    // If you add side effects (Tasks, observers, AVPlayer allocation) to
    // VideoDetailViewModel.init, those will fire N times per push instead of once.
    // Side effects belong in `.task {}`, `.onAppear`, or explicit lifecycle methods
    // called from the leaf view — NEVER in init.
    @State private var viewModel: VideoDetailViewModel

    init(make: () -> VideoDetailViewModel) {
        _viewModel = State(wrappedValue: make())
    }

    var body: some View {
        VideoDetailView(viewModel: viewModel)
    }
}
