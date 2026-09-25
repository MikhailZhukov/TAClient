import Testing
import Foundation
@testable import TAClient

/// Pure-function coverage for the iOS 27 resource-loader hardening:
/// range clamping (`requestedEndOffset`) and container UTI selection
/// (`contentTypeUTI`). `AVAssetResourceLoadingRequest` has no public
/// initializer, so the loader's request plumbing is exercised through these
/// seams.
@Suite struct ResourceLoaderRangeAndTypeTests {

    private let mp4URL = URL(string: "https://ta.example.com/media/videos/UC1/abc.mp4")!
    private let bareURL = URL(string: "https://ta.example.com/api/stream/abc")!

    // MARK: - requestedEndOffset

    @Test func toEnd_usesContentLength_ignoringRequestedLength() {
        let end = CachingResourceLoader.requestedEndOffset(
            requestedOffset: 1_000, requestedLength: 2,
            requestsAllDataToEnd: true, contentLength: 50_000
        )
        #expect(end == 50_000)
    }

    @Test func toEnd_unknownLength_returnsNil() {
        let end = CachingResourceLoader.requestedEndOffset(
            requestedOffset: 0, requestedLength: Int.max,
            requestsAllDataToEnd: true, contentLength: nil
        )
        #expect(end == nil)
    }

    @Test func rangePastEOF_isClampedToContentLength() {
        let end = CachingResourceLoader.requestedEndOffset(
            requestedOffset: 49_000, requestedLength: 16_000,
            requestsAllDataToEnd: false, contentLength: 50_000
        )
        #expect(end == 50_000)
    }

    @Test func rangeInsideResource_isUnchanged() {
        let end = CachingResourceLoader.requestedEndOffset(
            requestedOffset: 100, requestedLength: 2,
            requestsAllDataToEnd: false, contentLength: 50_000
        )
        #expect(end == 102)
    }

    @Test func offsetAtEOF_yieldsEmptyRange() {
        let end = CachingResourceLoader.requestedEndOffset(
            requestedOffset: 50_000, requestedLength: 1_024,
            requestsAllDataToEnd: false, contentLength: 50_000
        )
        #expect(end == 50_000)
    }

    @Test func hugeRequestedLength_doesNotOverflow() {
        let end = CachingResourceLoader.requestedEndOffset(
            requestedOffset: Int64.max - 10, requestedLength: Int.max,
            requestsAllDataToEnd: false, contentLength: nil
        )
        #expect(end == Int64.max)
    }

    @Test func unknownLength_fallsBackToRequestedRange() {
        let end = CachingResourceLoader.requestedEndOffset(
            requestedOffset: 10, requestedLength: 20,
            requestsAllDataToEnd: false, contentLength: 0
        )
        #expect(end == 30)
    }

    // MARK: - contentTypeUTI

    @Test func mp4Mime_mapsToMpeg4() {
        #expect(CachingResourceLoader.contentTypeUTI(mimeType: "video/mp4", url: bareURL) == "public.mpeg-4")
    }

    @Test func mimeParameters_areIgnored() {
        #expect(CachingResourceLoader.contentTypeUTI(mimeType: "Video/MP4; charset=binary", url: bareURL) == "public.mpeg-4")
    }

    @Test func quicktimeMime_mapsToQuickTime() {
        #expect(CachingResourceLoader.contentTypeUTI(mimeType: "video/quicktime", url: bareURL) == "com.apple.quicktime-movie")
    }

    @Test func octetStream_fallsBackToURLExtension() {
        #expect(CachingResourceLoader.contentTypeUTI(mimeType: "application/octet-stream", url: mp4URL) == "public.mpeg-4")
    }

    @Test func missingMime_fallsBackToURLExtension() {
        let movURL = URL(string: "https://ta.example.com/media/clip.mov")!
        #expect(CachingResourceLoader.contentTypeUTI(mimeType: nil, url: movURL) == "com.apple.quicktime-movie")
    }

    @Test func unknownEverything_defaultsToMpeg4_neverGenericMovie() {
        let uti = CachingResourceLoader.contentTypeUTI(mimeType: "application/octet-stream", url: bareURL)
        #expect(uti == "public.mpeg-4")
        #expect(uti != "public.movie")
    }

    // MARK: - pacingDelay

    private let mb: Int64 = 1024 * 1024

    @Test func pacing_initialBurst_isImmediate() {
        #expect(CachingResourceLoader.pacingDelay(deliveredBytes: 0, elapsedSeconds: 0) == 0)
        #expect(CachingResourceLoader.pacingDelay(deliveredBytes: 15 * mb, elapsedSeconds: 0) == 0)
    }

    @Test func pacing_pastBurst_waits() {
        let wait = CachingResourceLoader.pacingDelay(deliveredBytes: 28 * mb, elapsedSeconds: 0)
        #expect(wait > 0)
        #expect(wait <= 1.0)
    }

    @Test func pacing_allowanceGrowsWithTime() {
        // 16 MB burst + 12 MB/s × 2 s = 40 MB allowed.
        #expect(CachingResourceLoader.pacingDelay(deliveredBytes: 39 * mb, elapsedSeconds: 2) == 0)
        #expect(CachingResourceLoader.pacingDelay(deliveredBytes: 41 * mb, elapsedSeconds: 2) > 0)
    }

    @Test func pacing_waitIsCappedAtOneSecond() {
        #expect(CachingResourceLoader.pacingDelay(deliveredBytes: 1_000 * mb, elapsedSeconds: 0) == 1.0)
    }
}
