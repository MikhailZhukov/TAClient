import SwiftUI

/// Thin wrapper view that owns a `LoginViewModel` via `@State` so the VM is
/// constructed exactly once per view-identity instance (and torn down when the
/// view leaves the hierarchy).
///
/// Unlike the other `*Screen` wrappers — which sit inside a
/// `navigationDestination` and are pushed/popped — `LoginScreen` is the **root
/// of its `NavigationStack`** and is only re-instantiated when
/// `router.appState` flips between `.login` and `.authenticated`. Body re-evals
/// are correspondingly rare, so the antipattern's impact here is minimal — but
/// the wrapper is added for consistency with the other `*Screen` wrappers and
/// to set the template. See `VideoDetailScreen` for the original
/// production-confirmed instance of this antipattern.
struct LoginScreen: View {
    // INVARIANT: LoginViewModel.init must remain side-effect-free.
    // SwiftUI evaluates the `make` closure on every parent body re-eval; only the
    // FIRST result becomes @State storage, the rest are immediately discarded.
    // If you add side effects (Tasks, observers, network calls) to
    // LoginViewModel.init, those will fire N times per push instead of once.
    // Side effects belong in `.task {}`, `.onAppear`, or explicit lifecycle methods
    // called from the leaf view — NEVER in init.
    @State private var viewModel: LoginViewModel

    init(make: () -> LoginViewModel) {
        _viewModel = State(wrappedValue: make())
    }

    var body: some View {
        LoginView(viewModel: viewModel)
    }
}
