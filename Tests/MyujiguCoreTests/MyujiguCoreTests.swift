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
        let output = [
            "playing", "12500", "spotify:track:abc123", "Title | Remix", "Artist",
            "Test Album", "180000", "https://i.scdn.co/image/test-cover",
        ].joined(separator: separator)
        let state = SpotifyPlayer.parseState(output)

        XCTAssertEqual(state.player, .spotify)
        XCTAssertEqual(state.status, .playing)
        XCTAssertEqual(state.trackID, "abc123")
        XCTAssertEqual(state.positionMs, 12_500)
        XCTAssertEqual(state.title, "Title | Remix")
        XCTAssertEqual(state.album, "Test Album")
        XCTAssertEqual(state.durationMs, 180_000)
        XCTAssertEqual(state.artworkURL?.absoluteString, "https://i.scdn.co/image/test-cover")
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

    func testSystemNowPlayingStateParser() throws {
        let json = #"""
        {
          "title": "Browser Song",
          "artist": "Test Artist",
          "album": "Test Album",
          "duration": 193.091,
          "elapsedTime": 20.0,
          "calculatedPosition": 21.25,
          "playbackRate": 1,
          "uniqueIdentifier": "browser-track-1",
          "storeIdentifier": "1476727864",
          "mediaType": "Audio",
          "appName": "Test Browser",
          "bundleIdentifier": "com.example.browser"
        }
        """#
        let state = SystemNowPlayingPlayer.parseState(json)

        XCTAssertEqual(state.player, .system)
        XCTAssertEqual(state.status, .playing)
        XCTAssertEqual(state.positionMs, 21_250)
        XCTAssertEqual(state.durationMs, 193_091)
        XCTAssertEqual(state.title, "Browser Song")
        XCTAssertEqual(state.artist, "Test Artist")
        XCTAssertEqual(state.catalogID, "1476727864")
        XCTAssertEqual(state.sourceName, "Test Browser")
        XCTAssertEqual(state.bundleIdentifier, "com.example.browser")
        XCTAssertTrue(try XCTUnwrap(state.trackID).hasPrefix("now-playing:"))
        XCTAssertEqual(SystemNowPlayingPlayer.parseState(json).trackID, state.trackID)
    }

    func testSystemNowPlayingRecognizesNativePlayers() {
        XCTAssertTrue(
            SystemNowPlayingPlayer.isNativePlayer(
                bundleIdentifier: "com.spotify.client",
                sourceName: "Spotify"
            )
        )
        XCTAssertTrue(
            SystemNowPlayingPlayer.isNativePlayer(
                bundleIdentifier: "com.apple.Music",
                sourceName: "Music"
            )
        )
        XCTAssertFalse(
            SystemNowPlayingPlayer.isNativePlayer(
                bundleIdentifier: "com.example.browser",
                sourceName: "Test Browser"
            )
        )
    }

    func testLRCParserHandlesOffsetsFractionsAndRepeatedTimestamps() throws {
        let lrc = #"""
        [offset:+100]
        [00:01.20][00:03.250]First line
        [00:05.5]Second line
        """#
        let lyrics = try XCTUnwrap(LRCParser.parse(lrc, durationMs: 8_000))

        XCTAssertEqual(lyrics.provider, "LRCLIB")
        XCTAssertEqual(lyrics.syncType, "LINE_SYNCED")
        XCTAssertEqual(lyrics.lines.map(\.startTimeMs), [1_300, 3_350, 5_600])
        XCTAssertEqual(lyrics.lines.map(\.endTimeMs), [3_350, 5_600, 8_000])
        XCTAssertEqual(lyrics.lines.map(\.words), ["First line", "First line", "Second line"])
    }

    func testLRCLIBClientRequestsSecondsAndParsesSyncedLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myujigu-lrclib-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LRCLIBURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LRCLIBURLProtocolStub.handler = nil
        }
        LRCLIBURLProtocolStub.handler = { request in
            let response = #"""
            {
              "id": 42,
              "trackName": "Browser Song",
              "artistName": "Test Artist",
              "albumName": "Test Album",
              "duration": 193.091,
              "instrumental": false,
              "plainLyrics": "First line\nSecond line",
              "syncedLyrics": "[00:01.25]First line\n[00:04.00]Second line"
            }
            """#
            let http = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (http, Data(response.utf8))
        }

        let client = LRCLIBClient(
            baseURL: URL(string: "https://lrclib.test")!,
            session: session,
            cacheDirectory: directory
        )
        let lyrics = try await client.fetchLyrics(
            title: "Browser Song",
            artist: "Test Artist",
            album: "Test Album",
            durationMs: 193_091
        )

        XCTAssertEqual(lyrics?.provider, "LRCLIB")
        XCTAssertEqual(lyrics?.lines.map(\.startTimeMs), [1_250, 4_000])
        let request = try XCTUnwrap(LRCLIBURLProtocolStub.lastRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/get")
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "duration" }?.value,
            "193.091"
        )
    }

    func testAppleMusicTTMLParser() throws {
        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:itunes="http://itunes.apple.com/lyric-ttml-extensions"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata"
            xml:lang="en-US" itunes:timing="Line">
          <head><metadata>
            <ttm:title>Test Song</ttm:title>
            <ttm:agent type="person"><ttm:name type="full">Test Artist</ttm:name></ttm:agent>
            <songwriters xmlns="http://music.apple.com/lyric-ttml-internal">
              <songwriter>Test Writer</songwriter>
            </songwriters>
          </metadata></head>
          <body dur="00:00:08.500"><div>
            <p begin="00:00:01.250" end="00:00:03.500">First test line</p>
            <p begin="4.000s"><span>Second</span> <span>test line</span></p>
          </div></body>
        </tt>
        """#
        let data = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let document = try XCTUnwrap(AppleMusicLyricsParser.parseDocument(data))

        XCTAssertEqual(document.title, "Test Song")
        XCTAssertEqual(document.artists, ["Test Artist"])
        XCTAssertEqual(document.songwriters, ["Test Writer"])
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

    func testAppleMusicCacheMatchesCatalogMetadataWhenTTMLEndsBeforeTrack() async throws {
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
        let wrongTTML = #"""
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body dur="06:30.000"><div>
            <p begin="00:25.000" end="06:30.000">Lyrics from another song</p>
          </div></body>
        </tt>
        """#
        let wrongPayload = try JSONSerialization.data(withJSONObject: ["ttml": wrongTTML])
        let wrongPayloadHex = wrongPayload.map { String(format: "%02X", $0) }.joined()
        let metadata = try JSONSerialization.data(withJSONObject: [
            "results": [
                [
                    "id": "wrong-song",
                    "kind": "song",
                    "name": "Another Song",
                    "artistName": "Another Artist",
                    "collectionName": "Another Album",
                    "offers": [["assets": [["duration": 401]]]],
                ],
                [
                    "id": "981035788",
                    "kind": "song",
                    "name": "Metadata omitted by Apple",
                    "artistName": "Test Artist",
                    "collectionName": "Test Album",
                    "offers": [["assets": [["duration": 401]]]],
                ],
            ],
        ])
        let metadataHex = metadata.map { String(format: "%02X", $0) }.joined()
        let database = directory.appendingPathComponent("Cache.db")
        let query = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response VALUES(1, 'https://se2.itunes.apple.com/ttmlLyrics?id=981035788');
        INSERT INTO cfurl_cache_receiver_data VALUES(1, 0, X'\(payloadHex)');
        INSERT INTO cfurl_cache_response VALUES(2, 'https://se2.itunes.apple.com/ttmlLyrics?id=wrong-song');
        INSERT INTO cfurl_cache_receiver_data VALUES(2, 0, X'\(wrongPayloadHex)');
        INSERT INTO cfurl_cache_response VALUES(3, 'https://client-api.itunes.apple.com/lookup?id=playlist');
        INSERT INTO cfurl_cache_receiver_data VALUES(3, 0, X'\(metadataHex)');
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
            durationMs: 401_000,
            artist: "Test Artist",
            album: "Test Album"
        )
        XCTAssertEqual(lyrics?.lines.count, 1)
        XCTAssertEqual(lyrics?.lines[0].endTimeMs, 390_062)
    }

    func testAppleMusicCacheMatchesMetadataFromEditorialResponse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myujigu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="id">
          <body dur="3:13.091"><div>
            <p begin="15.761" end="23.914">A synchronized test line</p>
          </div></body>
        </tt>
        """#
        let payload = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined()
        let metadata = try JSONSerialization.data(withJSONObject: [
            "resources": [
                "songs": [
                    "6781391180": [
                        "id": "6781391180",
                        "type": "songs",
                        "attributes": [
                            "name": "MMG (My Mine Gueh)",
                            "artistName": "Naykilla",
                            "albumName": "MMG (My Mine Gueh) - Single",
                            "durationInMillis": 193_091,
                        ],
                    ],
                ],
            ],
        ])
        let metadataHex = metadata.map { String(format: "%02X", $0) }.joined()
        let database = directory.appendingPathComponent("Cache.db")
        let query = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response VALUES(1, 'https://se2.itunes.apple.com/ttmlLyrics?id=6781391180');
        INSERT INTO cfurl_cache_receiver_data VALUES(1, 0, X'\(payloadHex)');
        INSERT INTO cfurl_cache_response VALUES(2, 'https://amp-api-edge.music.apple.com/v1/editorial/id/groupings?name=music');
        INSERT INTO cfurl_cache_receiver_data VALUES(2, 0, X'\(metadataHex)');
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
            title: "MMG (My Mine Gueh)",
            durationMs: 193_091,
            artist: "Naykilla",
            album: "MMG (My Mine Gueh) - Single"
        )
        XCTAssertEqual(lyrics?.lines.count, 1)
        XCTAssertEqual(lyrics?.lines[0].startTimeMs, 15_761)
    }

    func testAppleMusicCacheMatchesTTMLSongwriterWhenMusicHidesPlainLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myujigu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en">
          <head><metadata>
            <ttm:agent type="person" xml:id="v1"/>
            <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
              <songwriters><songwriter>Taylor Swift</songwriter></songwriters>
            </iTunesMetadata>
          </metadata></head>
          <body dur="3:28.198"><div>
            <p begin="11.407" end="14.292">Knew he was a killer first time that I saw him</p>
          </div></body>
        </tt>
        """#
        let payload = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined()
        let database = directory.appendingPathComponent("Cache.db")
        let query = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response VALUES(1, 'https://se2.itunes.apple.com/ttmlLyrics?id=1445766080');
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
            title: "...Ready For It?",
            durationMs: 208_000,
            artist: "Taylor Swift"
        )
        XCTAssertEqual(
            lyrics?.lines.map(\.words),
            ["Knew he was a killer first time that I saw him"]
        )
    }

    func testAppleMusicCacheMatchesCatalogIDWithGenericVocalCredit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myujigu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml"
            xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xml:lang="en">
          <head><metadata>
            <ttm:agent type="person" xml:id="v1">
              <ttm:name type="full">Vocal 1</ttm:name>
            </ttm:agent>
            <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
              <songwriters>
                <songwriter>Stefani J. Germanotta</songwriter>
                <songwriter>Nadir Khayat</songwriter>
              </songwriters>
            </iTunesMetadata>
          </metadata></head>
          <body dur="3:57.078"><div>
            <p begin="24.393" end="27.878">A recently fetched synchronized line</p>
          </div></body>
        </tt>
        """#
        let payload = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined()
        let database = directory.appendingPathComponent("Cache.db")
        let query = """
        CREATE TABLE cfurl_cache_response(
          entry_ID INTEGER PRIMARY KEY,
          request_key TEXT,
          time_stamp TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response(entry_ID, request_key)
          VALUES(1, 'https://se2.itunes.apple.com/ttmlLyrics?id=1476727864');
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
            title: "Poker Face",
            durationMs: 237_078,
            artist: "Lady Gaga",
            album: "The Fame Monster (Deluxe Edition)",
            catalogID: "1476727864"
        )
        XCTAssertEqual(
            lyrics?.lines.map(\.words),
            ["A recently fetched synchronized line"]
        )
    }

    func testAppleMusicCacheRejectsDurationOnlyMatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("myujigu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ttml = #"""
        <tt xmlns="http://www.w3.org/ns/ttml" xml:lang="en">
          <body dur="03:00.000"><div>
            <p begin="00:10.000" end="03:00.000">Lyrics from another song</p>
          </div></body>
        </tt>
        """#
        let payload = try JSONSerialization.data(withJSONObject: ["ttml": ttml])
        let payloadHex = payload.map { String(format: "%02X", $0) }.joined()
        let database = directory.appendingPathComponent("Cache.db")
        let query = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY, request_key TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response VALUES(1, 'https://se2.itunes.apple.com/ttmlLyrics?id=wrong-song');
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
            title: "Current Song",
            durationMs: 180_000,
            artist: "Current Artist"
        )
        XCTAssertNil(lyrics)
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

private final class LRCLIBURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
