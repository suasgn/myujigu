import Foundation
@testable import MyujiguCore
import XCTest

final class MyujiguCoreTests: XCTestCase {
    func testLyricsParserAndActiveLine() throws {
        let json = #"""
        {
          "lyrics": {
            "syncType": "LINE_SYNCED",
            "provider": "Musixmatch",
            "language": "en",
            "lines": [
              {"startTimeMs":"1000","words":"First line","syllables":[]},
              {"startTimeMs":"2500","words":"Second line","syllables":[{"startTimeMs":"2500","count":6}]}
            ]
          }
        }
        """#

        let lyrics = try XCTUnwrap(LyricsParser.parse(Data(json.utf8)))
        XCTAssertEqual(lyrics.syncType, "LINE_SYNCED")
        XCTAssertEqual(lyrics.provider, "Musixmatch")
        XCTAssertEqual(lyrics.lines[0].endTimeMs, 2_500)
        XCTAssertEqual(lyrics.lines[1].endTimeMs, 12_500)
        XCTAssertNil(lyrics.activeLineIndex(at: 999))
        XCTAssertEqual(lyrics.activeLineIndex(at: 1_000), 0)
        XCTAssertEqual(lyrics.activeLineIndex(at: 3_000), 1)
    }

    func testUnsyncedLyricsHaveNoActiveLine() {
        let lyrics = Lyrics(
            syncType: "UNSYNCED",
            lines: [LyricLine(startTimeMs: 0, endTimeMs: 10_000, words: "A lyric")]
        )
        XCTAssertNil(lyrics.activeLineIndex(at: 5_000))
    }

    func testSpotifyLyricsCacheKeyExtractsOnlyTheTrackID() {
        let key = "1/0/_dk_https://spotify.com https://spotify.com "
            + "https://spclient.wg.spotify.com/color-lyrics/v2/track/abc123/image/cover"
            + "?format=json&market=from_token"

        XCTAssertEqual(CEFLyricsCache.lyricsTrackID(in: key), "abc123")
        XCTAssertNil(CEFLyricsCache.lyricsTrackID(in: "https://spotify.com/metadata/abc123"))
    }

    func testPlayerStateParserKeepsPunctuationInMetadata() {
        let separator = String(Character(UnicodeScalar(31)))
        let output = ["playing", "12500", "spotify:track:abc123", "Title | Remix", "Artist"].joined(separator: separator)
        let state = SpotifyPlayer.parseState(output)

        XCTAssertEqual(state.player, .spotify)
        XCTAssertEqual(state.status, .playing)
        XCTAssertEqual(state.trackID, "abc123")
        XCTAssertEqual(state.positionMs, 12_500)
        XCTAssertEqual(state.title, "Title | Remix")
    }

    func testAppleMusicPlayerStateParser() {
        let separator = String(Character(UnicodeScalar(31)))
        let output = [
            "playing", "12500", "ABCDEF1234", "Test Song", "Test Artist",
            "Test Album", "180000",
        ].joined(separator: separator)
        let state = AppleMusicPlayer.parseState(output)

        XCTAssertEqual(state.player, .appleMusic)
        XCTAssertEqual(state.status, .playing)
        XCTAssertEqual(state.trackID, "apple-music:ABCDEF1234")
        XCTAssertEqual(state.positionMs, 12_500)
        XCTAssertEqual(state.title, "Test Song")
        XCTAssertEqual(state.artist, "Test Artist")
        XCTAssertEqual(state.album, "Test Album")
        XCTAssertEqual(state.durationMs, 180_000)
    }

    func testAppleMusicTTMLParser() throws {
        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
            xml:lang="en-US" itunes:timing="Line">
          <head><metadata><ttm:title>Test Song</ttm:title></metadata></head>
          <body dur="00:00:08.500"><div>
            <p begin="00:00:01.250" end="00:00:03.500">First test line</p>
            <p begin="4.000s"><span>Second</span> <span>test line</span></p>
          </div></body>
        </tt>
        """#
        let data = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let document = try XCTUnwrap(AppleMusicLyricsParser.parseDocument(data))

        XCTAssertEqual(document.title, "Test Song")
        XCTAssertEqual(document.durationMs, 8_500)
        XCTAssertEqual(document.lyrics.provider, "Apple Music")
        XCTAssertEqual(document.lyrics.language, "en-US")
        XCTAssertEqual(document.lyrics.lines.count, 2)
        XCTAssertEqual(document.lyrics.lines[0].startTimeMs, 1_250)
        XCTAssertEqual(document.lyrics.lines[0].endTimeMs, 3_500)
        XCTAssertEqual(document.lyrics.lines[1].startTimeMs, 4_000)
        XCTAssertEqual(document.lyrics.lines[1].endTimeMs, 8_500)
        XCTAssertEqual(document.lyrics.lines[1].words, "Second test line")
    }

    func testAppleMusicParsesBareDecimalSecondsBeforeOneMinute() throws {
        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body dur="1:04.465"><div>
            <p begin="7.165" end="12.738">Early line</p>
            <p begin="57.269" end="1:04.465">Line before one minute</p>
          </div></body>
        </tt>
        """#
        let data = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let lyrics = try XCTUnwrap(AppleMusicLyricsParser.parse(data))

        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[0].startTimeMs, 7_165)
        XCTAssertEqual(lyrics.lines[0].endTimeMs, 12_738)
        XCTAssertEqual(lyrics.lines[1].startTimeMs, 57_269)
        XCTAssertEqual(lyrics.lines[1].endTimeMs, 64_465)
    }

    func testAppleMusicCacheMatchesTitlelessTTML() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myujigu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body dur="00:00:08.500"><div>
            <p begin="00:00:01.000" end="00:00:03.000">First test line</p>
            <p begin="00:00:04.000" end="00:00:08.500">Second test line</p>
          </div></body>
        </tt>
        """#
        let payload = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined()
        let database = directory.appendingPathComponent("Cache.db")
        let query = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response VALUES(1, 'https://se2.itunes.apple.com/ttmlLyrics?id=1');
        INSERT INTO cfurl_cache_receiver_data VALUES(1, 0, X'\(payloadHex)');
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, query]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let cache = AppleMusicLyricsCache(cacheDirectory: directory)
        let lyrics = await cache.findLyrics(
            title: "Test Song",
            durationMs: 8_500,
            plainLyrics: "First test line Second test line"
        )
        XCTAssertEqual(lyrics?.lines.count, 2)
        XCTAssertEqual(lyrics?.lines[1].startTimeMs, 4_000)
    }

    func testAppleMusicCacheAllowsTTMLToEndBeforeTrack() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myujigu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body dur="06:30.062"><div>
            <p begin="00:25.285" end="06:30.062">A synchronized test line</p>
          </div></body>
        </tt>
        """#
        let payload = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined()
        let database = directory.appendingPathComponent("Cache.db")
        let query = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response VALUES(1, 'https://se2.itunes.apple.com/ttmlLyrics?id=1');
        INSERT INTO cfurl_cache_receiver_data VALUES(1, 0, X'\(payloadHex)');
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, query]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let cache = AppleMusicLyricsCache(cacheDirectory: directory)
        let lyrics = await cache.findLyrics(
            title: "Metadata omitted by Apple",
            durationMs: 401_000
        )
        XCTAssertEqual(lyrics?.lines.count, 1)
        XCTAssertEqual(lyrics?.lines[0].endTimeMs, 390_062)
    }

    func testTOTPUsesRFCVector() {
        // RFC 6238's SHA-1 vector at Unix time 59 has 8 digits: 94287082.
        // The same dynamic truncation modulo 1,000,000 yields 287082.
        XCTAssertEqual(SpotifyAPI.totp(secret: "12345678901234567890", counter: 1), "287082")
    }

    func testSecretDictionaryDecoding() {
        let expected = "secret"
        let encoded = expected.utf8.enumerated().map { index, byte in
            Int(byte) ^ ((index % 33) + 9)
        }
        XCTAssertEqual(SpotifyAPI.decodeSecret(encoded), expected)
    }
}
