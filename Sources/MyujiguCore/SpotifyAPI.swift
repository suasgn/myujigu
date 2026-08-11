import CryptoKit
import Foundation

public enum SpotifyAPIError: LocalizedError, Sendable {
    case authentication(String)
    case request(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case let .authentication(message):
            return message
        case let .request(status):
            return "Spotify lyrics request failed (HTTP \(status))."
        case .malformedResponse:
            return "Spotify returned an unreadable lyrics response."
        }
    }
}

public actor SpotifyAPI {
    private struct CachedToken: Codable {
        let accessToken: String
        let expiresAtMs: Int64
    }

    private struct CachedLyrics: Codable {
        let fetchedAt: Date
        let lyrics: Lyrics
    }

    private struct SecretCache: Codable {
        let fetchedAt: Date
        let dictionary: [String: [Int]]
    }

    private struct LegacyTokenResponse: Decodable {
        let accessToken: String?
        let accessTokenExpirationTimestampMs: Int64?
        let isAnonymous: Bool?
    }

    private let cookie: String
    private let session: URLSession
    private let cacheDirectory: URL
    private var token: CachedToken?

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    private let secretURL = URL(string: "https://raw.githubusercontent.com/xyloflake/spot-secrets-go/main/secrets/secretDict.json")!

    public init(cookie: String, session: URLSession = .shared) {
        self.cookie = cookie
        self.session = session

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.cacheDirectory = applicationSupport
            .appendingPathComponent("Myujigu", isDirectory: true)
            .appendingPathComponent("Cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func fetchLyrics(trackID: String) async throws -> Lyrics? {
        if let cached: CachedLyrics = readJSON("lyrics-\(trackID).json"),
           Date().timeIntervalSince(cached.fetchedAt) < 6 * 60 * 60 {
            return cached.lyrics
        }

        let endpoints = [
            "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackID)?format=json&vocalRemoval=false&market=from_token",
            "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackID)?format=json&market=from_token",
        ]

        var lastStatus = 0
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            for attempt in 0..<2 {
                var request = URLRequest(url: url)
                request.setValue("Bearer \(try await accessToken(force: attempt > 0))", forHTTPHeaderField: "Authorization")
                request.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.malformedResponse }
                lastStatus = http.statusCode

                if http.statusCode == 401, attempt == 0 {
                    continue
                }
                if http.statusCode == 404 {
                    return nil
                }
                if http.statusCode == 200 {
                    guard let lyrics = LyricsParser.parse(data) else {
                        throw SpotifyAPIError.malformedResponse
                    }
                    writeJSON(CachedLyrics(fetchedAt: Date(), lyrics: lyrics), name: "lyrics-\(trackID).json")
                    return lyrics
                }
                break
            }
        }

        throw SpotifyAPIError.request(lastStatus)
    }

    private func accessToken(force: Bool) async throws -> String {
        if !force {
            if token == nil {
                token = readJSON("token.json")
            }
            if let token, token.expiresAtMs - 60_000 > Self.nowMilliseconds {
                return token.accessToken
            }
        }

        let fresh: CachedToken
        if let legacy = try await legacyToken() {
            fresh = legacy
        } else {
            fresh = try await totpToken()
        }
        token = fresh
        writeJSON(fresh, name: "token.json")
        return fresh.accessToken
    }

    private func legacyToken() async throws -> CachedToken? {
        guard let url = URL(string: "https://open.spotify.com/get_access_token?reason=transport&productType=web_player") else {
            return nil
        }
        var request = URLRequest(url: url)
        setCookieHeaders(on: &request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let value = try JSONDecoder().decode(LegacyTokenResponse.self, from: data)
            guard
                let accessToken = value.accessToken,
                let expiration = value.accessTokenExpirationTimestampMs,
                value.isAnonymous != true
            else {
                return nil
            }
            return CachedToken(accessToken: accessToken, expiresAtMs: expiration)
        } catch is DecodingError {
            return nil
        } catch {
            return nil
        }
    }

    private func totpToken() async throws -> CachedToken {
        let serverTimeURL = URL(string: "https://open.spotify.com/api/server-time")!
        var timeRequest = URLRequest(url: serverTimeURL)
        setCookieHeaders(on: &timeRequest)
        let (timeData, timeResponse) = try await session.data(for: timeRequest)
        guard let timeHTTP = timeResponse as? HTTPURLResponse, timeHTTP.statusCode == 200 else {
            throw SpotifyAPIError.authentication("Could not authenticate with Spotify (server time request failed).")
        }
        guard
            let timeObject = try JSONSerialization.jsonObject(with: timeData) as? [String: Any],
            let serverTime = (timeObject["serverTime"] as? NSNumber)?.int64Value
        else {
            throw SpotifyAPIError.authentication("Spotify returned an invalid server time.")
        }

        let dictionary = try await secretDictionary()
        guard
            let latestVersion = dictionary.keys.compactMap(Int.init).max(),
            let encodedSecret = dictionary[String(latestVersion)]
        else {
            throw SpotifyAPIError.authentication("No Spotify TOTP secret is available.")
        }

        let secret = Self.decodeSecret(encodedSecret)
        let code = Self.totp(secret: secret, counter: UInt64(serverTime / 30))
        var components = URLComponents(string: "https://open.spotify.com/api/token")!
        components.queryItems = [
            URLQueryItem(name: "reason", value: "init"),
            URLQueryItem(name: "productType", value: "web-player"),
            URLQueryItem(name: "totp", value: code),
            URLQueryItem(name: "totpVer", value: String(latestVersion)),
            URLQueryItem(name: "ts", value: String(serverTime * 1_000)),
        ]

        var tokenRequest = URLRequest(url: components.url!)
        setCookieHeaders(on: &tokenRequest)
        tokenRequest.setValue("https://open.spotify.com", forHTTPHeaderField: "Origin")
        tokenRequest.setValue("https://open.spotify.com/", forHTTPHeaderField: "Referer")
        tokenRequest.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
        let (tokenData, tokenResponse) = try await session.data(for: tokenRequest)
        guard let tokenHTTP = tokenResponse as? HTTPURLResponse, tokenHTTP.statusCode == 200 else {
            let status = (tokenResponse as? HTTPURLResponse)?.statusCode ?? 0
            throw SpotifyAPIError.authentication("Could not authenticate with Spotify (HTTP \(status)).")
        }

        let value = try JSONDecoder().decode(LegacyTokenResponse.self, from: tokenData)
        guard
            let accessToken = value.accessToken,
            let expiration = value.accessTokenExpirationTimestampMs,
            value.isAnonymous != true
        else {
            throw SpotifyAPIError.authentication("The sp_dc cookie is invalid or expired.")
        }
        return CachedToken(accessToken: accessToken, expiresAtMs: expiration)
    }

    private func secretDictionary() async throws -> [String: [Int]] {
        if let cached: SecretCache = readJSON("totp-secrets.json"),
           Date().timeIntervalSince(cached.fetchedAt) < 24 * 60 * 60 {
            return cached.dictionary
        }

        let (data, response) = try await session.data(from: secretURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SpotifyAPIError.authentication("Could not update Spotify authentication data.")
        }
        let dictionary = try JSONDecoder().decode([String: [Int]].self, from: data)
        writeJSON(SecretCache(fetchedAt: Date(), dictionary: dictionary), name: "totp-secrets.json")
        return dictionary
    }

    private func setCookieHeaders(on request: inout URLRequest) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("sp_dc=\(cookie)", forHTTPHeaderField: "Cookie")
    }

    private func readJSON<T: Decodable>(_ name: String) -> T? {
        let url = cacheDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, name: String) {
        let url = cacheDirectory.appendingPathComponent(name)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static var nowMilliseconds: Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    static func decodeSecret(_ integers: [Int]) -> String {
        let scalars = integers.enumerated().compactMap { index, value in
            UnicodeScalar(value ^ ((index % 33) + 9))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func totp(secret: String, counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let counterData = withUnsafeBytes(of: &bigEndian) { Data($0) }
        let key = SymmetricKey(data: Data(secret.utf8))
        let authentication = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let digest = Array(authentication)
        let offset = Int(digest[digest.count - 1] & 0x0f)
        let value = (UInt32(digest[offset] & 0x7f) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])
        return String(format: "%06d", value % 1_000_000)
    }
}
