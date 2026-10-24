import Foundation

@main struct TransportTests {
    static func main() throws {
        var t = Transport(count: 3)
        t.skipForward(); t.skipForward(); t.skipForward()
        assert(t.index == 0, "a tap past the last track wraps to the first")
        t.time = 10; t.skipBack()
        assert(t.index == 0 && t.time == 0, "back inside a track restarts it")
        t.skipBack()
        assert(t.index == 2, "back at the start goes to the previous track, wrapping")
        assert(!t.ended() && t.index == 2, "the last track ending stops the disc")
        t.index = 0
        assert(t.ended() && t.index == 1, "a track ending moves to the next")
        var empty = Transport(count: 0)
        empty.skipForward(); empty.skipBack()
        assert(!empty.ended() && empty.index == 0, "an empty disc stays put")
        var single = Transport(count: 1)
        single.time = 1; single.skipBack()
        assert(single.index == 0 && single.time == 0, "one track: back restarts it")
        assert(clock(0) == "00:00" && clock(65.9) == "01:05" && clock(.nan) == "00:00" && clock(3600) == "60:00" && clock(-2) == "00:00")

        let json = #"{"Items":[{"Name":"Flower","Id":"abc","Album":"Pecan Grove","AlbumId":"al1","Artists":["Blue Dot Sessions"],"RunTimeTicks":300000000,"IndexNumber":2,"Type":"Audio"}],"TotalRecordCount":1}"#
        let tracks: [Track] = try Jellyfin.decode(Data(json.utf8))
        assert(tracks.count == 1 && tracks[0].name == "Flower" && tracks[0].albumId == "al1" && tracks[0].seconds == 30
               && tracks[0].artist == "Blue Dot Sessions", "Jellyfin's PascalCase decodes into the models")
        let bare: [Track] = try Jellyfin.decode(Data(#"{"Items":[{"Name":"x","Id":"1"}]}"#.utf8))
        assert(bare[0].artist == "" && bare[0].seconds == 0, "a track with no tags still decodes")
        assert(tracks[0].artId == "al1" && bare[0].artId == "1", "album picture when there is one, else the song's own")

        let jf = Jellyfin(server: "https://h.example:8920", token: "tok", userId: "u1")
        let url = jf.stream(tracks[0])!.absoluteString
        assert(url.hasPrefix("https://h.example:8920/Audio/abc/universal?") && url.contains("api_key=tok") && url.contains("userId=u1"), url)
        assert(jf.artwork("al1")!.absoluteString == "https://h.example:8920/Items/al1/Images/Primary?fillWidth=600&fillHeight=600&quality=90")
        assert(Jellyfin.normalize(" haruserver.tail6da04d.ts.net:8920/ ") == "https://haruserver.tail6da04d.ts.net:8920")
        assert(Jellyfin.normalize("http://10.0.0.2:8096") == "http://10.0.0.2:8096")
        assert(Jellyfin.authorization(token: "t").hasSuffix(", Token=\"t\"") && Jellyfin.authorization(token: nil).hasPrefix("MediaBrowser Client=\"Spin\""))

        // yubal's job list, trimmed from its v0.10.0 schema (snake_case, oldest first).
        let jobsJSON = #"{"jobs":[{"id":"a","url":"https://music.youtube.com/watch?v=x","status":"completed","progress":100.0,"content_info":{"title":"Song","artist":"Band","thumbnail_url":"https://i.ytimg.com/x.jpg","track_count":1,"kind":"track"}},{"id":"b","url":"https://music.youtube.com/playlist?list=y","status":"downloading","progress":42.5,"content_info":null}]}"#
        let jobs = try Yubal.decode(Data(jobsJSON.utf8))
        assert(jobs.map(\.id) == ["b", "a"], "newest job first")
        assert(jobs[1].contentInfo?.thumbnailUrl == "https://i.ytimg.com/x.jpg" && jobs[1].finished && jobs[1].label == "In library")
        assert(!jobs[0].finished && jobs[0].progress == 42.5 && jobs[0].contentInfo == nil)
        assert(Yubal.isLink("https://music.youtube.com/watch?v=abc") && Yubal.isLink(" https://youtu.be/abc ") && Yubal.isLink("https://www.youtube.com/playlist?list=x"))
        assert(!Yubal.isLink("https://evil-youtube.com/x") && !Yubal.isLink("hello") && !Yubal.isLink("https://soundcloud.com/x"))
        let invalid = YubalError(code: 422, body: Data(#"{"detail":[{"msg":"Value error, Invalid URL."}]}"#.utf8))
        assert(invalid.errorDescription == "Value error, Invalid URL.")
        assert(YubalError(code: 0, body: Data()).errorDescription!.contains("Tailscale"))

        let found = try Sources.decodeResults(Data(#"{"results":[{"kind":"song","title":"T","artist":"A","detail":"Al","duration":"4:40","thumbnail":null,"url":"https://music.youtube.com/watch?v=x"}]}"#.utf8))
        assert(found.count == 1 && found[0].id == "https://music.youtube.com/watch?v=x" && found[0].thumbnail == nil)
        assert(Sources.isSoundCloud("https://soundcloud.com/a/b") && Sources.isSoundCloud("https://on.soundcloud.com/x"))
        assert(!Sources.isSoundCloud("http://soundcloud.com/a") && !Sources.isSoundCloud("https://soundcloud.com.evil.net/a") && !Sources.isSoundCloud("https://music.youtube.com/x"))
        assert(Sources.defaultServer == "https://haruserver.tail6da04d.ts.net:8930/sources")
        print("transport ok")
    }
}
