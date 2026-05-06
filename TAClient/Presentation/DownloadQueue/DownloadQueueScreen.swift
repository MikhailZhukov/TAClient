import SwiftUI

/// Thin wrapper view that owns a `DownloadQueueViewModel` via `@State` so the
/// VM is constructed exactly once per `NavigationStack` push (and torn down
/// once per pop).
///
/// Without this wrapper, every `navigationDestination` body re-evaluation in
/// `TAClientApp` would call `container.makeDownloadQueueViewModel()` inline,
/// creating a new VM on every parent body re-render. SwiftUI keeps the
/// previous VM alive as long as it holds a reference, so multiple parallel VMs
/// accumulate. See `VideoDetailScreen` for the original production-confirmed
/// instance of this antipattern.
struct DownloadQueueScreen: View {
    // INVARIANT: DownloadQueueViewModel.init must remain side-effect-free.
    // SwiftUI evaluates the `make` closure on every parent body re-eval; only the
    // FIRST result becomes @State storage, the rest are immediately discarded.
    // If you add side effects (Tasks, observers, network calls) to
    // DownloadQueueViewModel.init, those will fire N times per push instead of once.
    // Side effects belong in `.task {}`, `.onAppear`, or explicit lifecycle methods
    // called from the leaf view — NEVER in init.
    @State private var viewModel: DownloadQueueViewModel

    init(make: () -> DownloadQueueViewModel) {
        _viewModel = State(wrappedValue: make())
    }

    var body: some View {
        DownloadQueueView(viewModel: viewModel)
    }
}
