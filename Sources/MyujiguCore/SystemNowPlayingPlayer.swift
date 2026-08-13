import Foundation

/// Reads the system Control Center's active media session. Starting in macOS
/// 15.4, mediaremoted rejects the older C callbacks from third-party processes.
/// Running MRNowPlayingRequest through Apple's signed JXA host keeps the private
/// API usable without requiring private entitlements or disabling SIP.
public struct SystemNowPlayingPlayer: Sendable {
    private struct Snapshot: Decodable {
        let title: String?
        let artist: String?
        let album: String?
        let duration: Double?
        let elapsedTime: Double?
        let calculatedPosition: Double?
        let playbackRate: Double?
        let uniqueIdentifier: String?
        let storeIdentifier: String?
        let mediaType: String?
        let appName: String?
        let bundleIdentifier: String?
    }

    private static let stateScript = #"""
    ObjC.import('Foundation');

    function unwrap(value) {
        if (value === undefined || value === null) return null;
        try { return ObjC.unwrap(value); } catch (_) { return null; }
    }

    function property(object, name) {
        if (!object) return null;
        try { return unwrap(object[name]); } catch (_) { return null; }
    }

    function text(value) {
        return value === undefined || value === null ? null : String(value);
    }

    function run() {
        const framework = $.NSBundle.bundleWithPath(
            '/System/Library/PrivateFrameworks/MediaRemote.framework/'
        );
        if (!framework || !framework.load) return '{}';

        const request = $.NSClassFromString('MRNowPlayingRequest');
        if (!request) return '{}';
        const item = request.localNowPlayingItem;
        const playerPath = request.localNowPlayingPlayerPath;
        const info = item ? item.nowPlayingInfo : null;
        const client = playerPath ? playerPath.client : null;
        if (!item || !info) return '{}';

        function value(key) {
            try { return unwrap(info.valueForKey(key)); } catch (_) { return null; }
        }

        let calculatedPosition = null;
        try {
            calculatedPosition = item.metadata
                ? unwrap(item.metadata.calculatedPlaybackPosition)
                : null;
        } catch (_) {}

        return JSON.stringify({
            title: value('kMRMediaRemoteNowPlayingInfoTitle'),
            artist: value('kMRMediaRemoteNowPlayingInfoArtist'),
            album: value('kMRMediaRemoteNowPlayingInfoAlbum'),
            duration: value('kMRMediaRemoteNowPlayingInfoDuration'),
            elapsedTime: value('kMRMediaRemoteNowPlayingInfoElapsedTime'),
            calculatedPosition: calculatedPosition,
            playbackRate: value('kMRMediaRemoteNowPlayingInfoPlaybackRate'),
            uniqueIdentifier: text(value('kMRMediaRemoteNowPlayingInfoUniqueIdentifier')),
            storeIdentifier: text(value('kMRMediaRemoteNowPlayingInfoiTunesStoreIdentifier')),
            mediaType: value('kMRMediaRemoteNowPlayingInfoMediaType'),
            appName: property(client, 'displayName'),
            bundleIdentifier: property(client, 'bundleIdentifier')
        });
    }
    """#

    private static let artworkScript = #"""
    ObjC.import('Foundation');

    function run() {
        const framework = $.NSBundle.bundleWithPath(
            '/System/Library/PrivateFrameworks/MediaRemote.framework/'
        );
        if (!framework || !framework.load) return '';
        const request = $.NSClassFromString('MRNowPlayingRequest');
        const item = request ? request.localNowPlayingItem : null;
        const info = item ? item.nowPlayingInfo : null;
        if (!info) return '';
        try {
            const data = info.valueForKey('kMRMediaRemoteNowPlayingInfoArtworkData');
            if (!data) return '';
            return ObjC.unwrap(data.base64EncodedStringWithOptions(0));
        } catch (_) {
            return '';
        }
    }
    """#

    public init() {}

    public func currentState() async -> PlayerState {
        await Task.detached(priority: .utility) {
            let result = Self.runJXA(Self.stateScript)
            guard result.status == 0 else {
                return PlayerState(
                    status: .unavailable,
                    player: .system,
                    trackID: nil,
                    positionMs: 0,
                    title: "",
                    artist: ""
                )
            }
            return Self.parseState(result.output)
        }.value
    }

    public func currentArtworkData() async -> Data? {
        await Task.detached(priority: .utility) {
            let result = Self.runJXA(Self.artworkScript)
            guard result.status == 0 else { return nil }
            let encoded = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !encoded.isEmpty else { return nil }
            return Data(base64Encoded: encoded)
        }.value
    }

    public func send(_ command: SpotifyCommand) async {
        let commandValue = switch command {
        case .playPause: 2
        case .next: 4
        case .previous: 5
        }
        let source = """
        ObjC.import('Foundation');
        function run() {
            const framework = $.NSBundle.bundleWithPath(
                '/System/Library/PrivateFrameworks/MediaRemote.framework/'
            );
            if (!framework || !framework.load) return false;
            const controllerClass = $.NSClassFromString('MRNowPlayingController');
            if (!controllerClass) return false;
            const controller = controllerClass.localRouteController;
            const options = $.NSDictionary.alloc.init;
            controller.sendCommandOptionsCompletion(\(commandValue), options, null);
            return true;
        }
        """
        await Task.detached(priority: .userInitiated) {
            _ = Self.runJXA(source)
        }.value
    }

    public static func parseState(_ output: String) -> PlayerState {
        let data = Data(output.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return PlayerState(
                status: .unavailable,
                player: .system,
                trackID: nil,
                positionMs: 0,
                title: "",
                artist: ""
            )
        }

        let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return .stopped }
        let artist = snapshot.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = snapshot.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let durationMs = milliseconds(snapshot.duration)
        let rawPosition = snapshot.calculatedPosition ?? snapshot.elapsedTime
        let unclampedPositionMs = max(milliseconds(rawPosition), 0)
        let positionMs = durationMs > 0
            ? min(unclampedPositionMs, durationMs)
            : unclampedPositionMs
        let bundleIdentifier = snapshot.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceName = snapshot.appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = [
            bundleIdentifier ?? sourceName ?? "system",
            snapshot.uniqueIdentifier ?? "",
            title,
            artist,
            album,
            String(durationMs),
        ].joined(separator: String(Character(UnicodeScalar(31))))
        let rawCatalogID = snapshot.storeIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // MediaRemote stores numeric values in NSNumber. JXA stringifies
        // those as ordinary decimal identifiers before JSON encoding.
        let catalogID: String? = if let rawCatalogID,
                                    !rawCatalogID.isEmpty,
                                    rawCatalogID != "0",
                                    rawCatalogID.allSatisfy(\.isNumber)
        {
            rawCatalogID
        } else {
            nil
        }

        return PlayerState(
            status: (snapshot.playbackRate ?? 0) > 0 ? .playing : .paused,
            player: .system,
            trackID: "now-playing:\(stableHash(identity))",
            positionMs: positionMs,
            title: title,
            artist: artist,
            album: album,
            durationMs: durationMs,
            catalogID: catalogID,
            sourceName: sourceName?.isEmpty == false ? sourceName : nil,
            bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        )
    }

    public static func isNativePlayer(
        bundleIdentifier: String?,
        sourceName: String?
    ) -> Bool {
        nativePlayerKind(
            bundleIdentifier: bundleIdentifier,
            sourceName: sourceName
        ) != nil
    }

    public static func nativePlayerKind(
        bundleIdentifier: String?,
        sourceName: String?
    ) -> PlayerKind? {
        let bundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        if bundleIdentifier == "com.spotify.client" {
            return .spotify
        }
        if bundleIdentifier == "com.apple.music" {
            return .appleMusic
        }
        let sourceName = sourceName?.lowercased() ?? ""
        if sourceName == "spotify" {
            return .spotify
        }
        if sourceName == "music" || sourceName == "apple music" {
            return .appleMusic
        }
        return nil
    }

    private static func milliseconds(_ seconds: Double?) -> Int {
        guard let seconds, seconds.isFinite, seconds > 0 else { return 0 }
        let milliseconds = seconds * 1_000
        guard milliseconds < Double(Int.max) else { return Int.max }
        return Int(milliseconds.rounded())
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func runJXA(_ source: String) -> (status: Int32, output: String) {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }
}
