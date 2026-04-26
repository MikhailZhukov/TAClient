import SwiftUI
import Testing
@testable import TAClient

struct SearchViewModelTests {

    private func makeSUT(
        searchRepo: MockSearchRepository = MockSearchRepository()
    ) -> (SearchViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = SearchViewModel(searchRepository: searchRepo, router: router)
        return (vm, router)
    }

    @Test func emptyQuery_clearsVideos() {
        let (vm, _) = makeSUT()
        vm.query = ""
        vm.onQueryChanged()

        #expect(vm.videos.isEmpty)
        #expect(vm.hasSearched == false)
    }

    @Test func validQuery_populatesVideos() async throws {
        let repo = MockSearchRepository()
        repo.searchHandler = { query, _ in
            SearchResult(
                videos: [TestData.video(youtubeId: "s1"), TestData.video(youtubeId: "s2")],
                channels: []
            )
        }
        let (vm, _) = makeSUT(searchRepo: repo)

        vm.query = "test search"
        vm.onQueryChanged()

        // Wait for debounce (300ms) + search execution
        try await Task.sleep(for: .milliseconds(500))

        #expect(vm.videos.count == 2)
        #expect(vm.hasSearched == true)
    }

    @Test func unauthorized_routerHandles() async throws {
        let repo = MockSearchRepository()
        repo.searchHandler = { _, _ in throw AppError.unauthorized }
        let (vm, router) = makeSUT(searchRepo: repo)

        vm.query = "test"
        vm.onQueryChanged()

        try await Task.sleep(for: .milliseconds(500))

        #expect(router.appState == .login)
    }

    @Test func isLoading_togglesDuringSearch() async throws {
        let repo = MockSearchRepository()
        repo.searchHandler = { _, _ in
            SearchResult(videos: [TestData.video()], channels: [])
        }
        let (vm, _) = makeSUT(searchRepo: repo)

        #expect(vm.isLoading == false)

        vm.query = "test"
        vm.onQueryChanged()

        try await Task.sleep(for: .milliseconds(500))

        #expect(vm.isLoading == false)
    }

    @Test func navigation_appendsRoutes() {
        let (vm, router) = makeSUT()

        vm.navigateToVideo("vid-1")
        #expect(router.path.count == 1)

        vm.navigateToChannel("ch-1")
        #expect(router.path.count == 2)
    }
}
