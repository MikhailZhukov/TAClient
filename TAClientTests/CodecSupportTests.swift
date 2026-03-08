import Testing
@testable import TAClient

struct CodecSupportTests {

    @Test func emptyStreams_returnsAVPlayer() {
        let result = CodecSupport.requiredPlayer(for: [])
        #expect(result == .avPlayer)
    }

    @Test func h264VideoOnly_returnsAVPlayer() {
        let streams = [StreamInfo(type: "video", codec: "h264", bitrate: 5000, width: 1920, height: 1080)]
        #expect(CodecSupport.requiredPlayer(for: streams) == .avPlayer)
    }

    @Test func vp9Video_returnsVLCPlayer() {
        let streams = [StreamInfo(type: "video", codec: "vp9", bitrate: 5000, width: 1920, height: 1080)]
        #expect(CodecSupport.requiredPlayer(for: streams) == .vlcPlayer)
    }

    @Test func vp8Video_returnsVLCPlayer() {
        let streams = [StreamInfo(type: "video", codec: "vp8", bitrate: 3000, width: 1280, height: 720)]
        #expect(CodecSupport.requiredPlayer(for: streams) == .vlcPlayer)
    }

    @Test func vp09Variant_returnsVLCPlayer() {
        let streams = [StreamInfo(type: "video", codec: "vp09", bitrate: 5000, width: 1920, height: 1080)]
        #expect(CodecSupport.requiredPlayer(for: streams) == .vlcPlayer)
    }

    @Test func caseInsensitive_VP9_returnsVLCPlayer() {
        let streams = [StreamInfo(type: "video", codec: "VP9", bitrate: 5000, width: 1920, height: 1080)]
        #expect(CodecSupport.requiredPlayer(for: streams) == .vlcPlayer)
    }

    @Test func av1Video_returnsAVPlayer() {
        let streams = [StreamInfo(type: "video", codec: "av1", bitrate: 5000, width: 3840, height: 2160)]
        #expect(CodecSupport.requiredPlayer(for: streams) == .avPlayer)
    }

    @Test func opusAudio_returnsAVPlayer() {
        let streams = [StreamInfo(type: "audio", codec: "opus", bitrate: 128, width: nil, height: nil)]
        #expect(CodecSupport.requiredPlayer(for: streams) == .avPlayer)
    }

    @Test func mixedH264AndVP9_returnsVLCPlayer() {
        let streams = [
            StreamInfo(type: "video", codec: "h264", bitrate: 5000, width: 1920, height: 1080),
            StreamInfo(type: "video", codec: "vp9", bitrate: 3000, width: 1280, height: 720),
            StreamInfo(type: "audio", codec: "opus", bitrate: 128, width: nil, height: nil)
        ]
        #expect(CodecSupport.requiredPlayer(for: streams) == .vlcPlayer)
    }
}
