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
        let albums: [Album] = try Jellyfin.decode(Data(#"{"Items":[{"Name":"Pecan Grove","Id":"al1","AlbumArtist":"Blue Dot Sessions","ProductionYear":2015}]}"#.utf8))
        assert(albums[0].albumArtist == "Blue Dot Sessions" && albums[0].productionYear == 2015)

        let jf = Jellyfin(server: "https://h.example:8920", token: "tok", userId: "u1")
        let url = jf.stream(tracks[0])!.absoluteString
        assert(url.hasPrefix("https://h.example:8920/Audio/abc/universal?") && url.contains("api_key=tok") && url.contains("userId=u1"), url)
        assert(jf.artwork("al1")!.absoluteString == "https://h.example:8920/Items/al1/Images/Primary?fillWidth=600&fillHeight=600&quality=90")
        assert(Jellyfin.normalize(" haruserver.tail6da04d.ts.net:8920/ ") == "https://haruserver.tail6da04d.ts.net:8920")
        assert(Jellyfin.normalize("http://10.0.0.2:8096") == "http://10.0.0.2:8096")
        assert(Jellyfin.authorization(token: "t").hasSuffix(", Token=\"t\"") && Jellyfin.authorization(token: nil).hasPrefix("MediaBrowser Client=\"Spin\""))
        print("transport ok")
    }
}
