import Foundation

public actor CEFLyricsCache {
    private static let entryMagic: UInt64 = 0xfcfb6d1ba7725c30
    private static let headerSize = 24
    private static let eofMagic: [UInt8] = [0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4]
    private static let httpMagic = Array("HTTP/".utf8)
    private static let lyricsPath = "color-lyrics/v2/track/"

    private let baseDirectory: URL
    private var index: [String: [URL]] = [:]
    private var directoryDates: [URL: Date?] = [:]

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.spotify.client", isDirectory: true)
    }

    public func findLyrics(trackID: String) -> Lyrics? {
        refreshIndexIfNeeded()

        for url in index[trackID] ?? [] {
            if let lyrics = readLyrics(url: url) {
                return lyrics
            }
        }

        // Spotify may have written a new cache entry without updating the directory
        // timestamp visible to our first scan.
        rebuildIndex()
        for url in index[trackID] ?? [] {
            if let lyrics = readLyrics(url: url) {
                return lyrics
            }
        }
        return nil
    }

    private func cacheDirectories() -> [URL] {
        let fileManager = FileManager.default
        guard let profiles = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [baseDirectory.appendingPathComponent("Default/Cache/Cache_Data", isDirectory: true)]
        }

        let directories = profiles.compactMap { profile -> URL? in
            let cacheData = profile.appendingPathComponent("Cache/Cache_Data", isDirectory: true)
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: cacheData.path, isDirectory: &isDirectory) && isDirectory.boolValue
                ? cacheData
                : nil
        }
        return directories.isEmpty
            ? [baseDirectory.appendingPathComponent("Default/Cache/Cache_Data", isDirectory: true)]
            : directories
    }

    private func refreshIndexIfNeeded() {
        let directories = cacheDirectories()
        let dates = Dictionary(uniqueKeysWithValues: directories.map { directory in
            let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
            return (directory, values?.contentModificationDate)
        })
        if index.isEmpty || dates != directoryDates {
            rebuildIndex(directories: directories, dates: dates)
        }
    }

    private func rebuildIndex(directories: [URL]? = nil, dates: [URL: Date?]? = nil) {
        let fileManager = FileManager.default
        let directories = directories ?? cacheDirectories()
        var fresh: [String: [URL]] = [:]

        for directory in directories {
            guard let files = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else {
                continue
            }
            for case let file as URL in files where file.lastPathComponent.hasSuffix("_0") {
                autoreleasepool {
                    if let key = readKey(file),
                       let trackID = Self.lyricsTrackID(in: key)
                    {
                        fresh[trackID, default: []].append(file)
                    }
                }
            }
        }

        index = fresh
        if let dates {
            directoryDates = dates
        } else {
            directoryDates = Dictionary(uniqueKeysWithValues: directories.map { directory in
                let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
                return (directory, values?.contentModificationDate)
            })
        }
    }

    static func lyricsTrackID(in cacheKey: String) -> String? {
        guard let pathRange = cacheKey.range(of: lyricsPath) else { return nil }
        let suffix = cacheKey[pathRange.upperBound...]
        let trackID = suffix.prefix {
            $0 != "/" && $0 != "?" && $0 != "#" && !$0.isWhitespace
        }
        return trackID.isEmpty ? nil : String(trackID)
    }

    private func readKey(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard
            let header = try? handle.read(upToCount: Self.headerSize),
            header.count == Self.headerSize,
            littleEndianUInt64(header, at: 0) == Self.entryMagic,
            let keyLengthValue = littleEndianUInt32(header, at: 12)
        else {
            return nil
        }
        let keyLength = Int(keyLengthValue)
        guard keyLength > 0, keyLength <= 4_096 else { return nil }
        guard let keyData = try? handle.read(upToCount: keyLength), keyData.count == keyLength else {
            return nil
        }
        return String(data: keyData, encoding: .utf8)
    }

    private func readLyrics(url: URL) -> Lyrics? {
        guard
            let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
            littleEndianUInt64(data, at: 0) == Self.entryMagic,
            let keyLengthValue = littleEndianUInt32(data, at: 12)
        else {
            return nil
        }

        let bytes = [UInt8](data)
        let bodyStart = Self.headerSize + Int(keyLengthValue)
        guard
            bodyStart < bytes.count,
            let firstEOF = Self.index(of: Self.eofMagic, in: bytes, startingAt: bodyStart)
        else {
            return nil
        }

        let body = Data(bytes[bodyStart..<firstEOF])
        let metadataStart = firstEOF + 24
        guard
            let httpStart = Self.index(of: Self.httpMagic, in: bytes, startingAt: metadataStart),
            let headerEnd = Self.index(of: [0, 0], in: bytes, startingAt: httpStart)
        else {
            return nil
        }

        let headerData = Data(bytes[httpStart..<headerEnd])
        let headerText = String(decoding: headerData, as: UTF8.self)
        let fields = headerText.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard let statusLine = fields.first, statusLine.split(separator: " ").dropFirst().first == "200" else {
            return nil
        }

        var headers: [String: String] = [:]
        for field in fields.dropFirst() {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let name = field[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let decoded = Self.decode(body, contentEncoding: headers["content-encoding"] ?? "")
        return decoded.flatMap(LyricsParser.parse)
    }

    private func littleEndianUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, data.count >= offset + 8 else { return nil }
        return (0..<8).reduce(UInt64(0)) { value, index in
            value | (UInt64(data[data.startIndex + offset + index]) << UInt64(index * 8))
        }
    }

    private func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, data.count >= offset + 4 else { return nil }
        return (0..<4).reduce(UInt32(0)) { value, index in
            value | (UInt32(data[data.startIndex + offset + index]) << UInt32(index * 8))
        }
    }

    private static func index(of needle: [UInt8], in haystack: [UInt8], startingAt start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, start <= haystack.count - needle.count else { return nil }
        for index in start...(haystack.count - needle.count) {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
        }
        return nil
    }

    private static func decode(_ data: Data, contentEncoding: String) -> Data? {
        let encoding = contentEncoding.lowercased()
        if encoding.isEmpty || encoding == "identity" {
            return data
        }
        if encoding.contains("gzip") {
            return runDecoder(candidates: ["/usr/bin/gzip"], arguments: ["-dc"], data: data)
        }
        if encoding.contains("br") {
            return runDecoder(
                candidates: ["/opt/homebrew/bin/brotli", "/usr/local/bin/brotli"],
                arguments: ["-d", "-c"],
                data: data
            )
        }
        if encoding.contains("zstd") {
            return runDecoder(
                candidates: ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"],
                arguments: ["-d", "-c", "--quiet"],
                data: data
            )
        }
        return data
    }

    private static func runDecoder(candidates: [String], arguments: [String], data: Data) -> Data? {
        let fileManager = FileManager.default
        guard let executable = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            return nil
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            stdin.fileHandleForWriting.write(data)
            try stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? output : nil
        } catch {
            return nil
        }
    }
}
