import Foundation

public struct LiveWordHighlight: Equatable, Sendable {
    public let lineIndex: Int
    public let utf16Offset: Int
    public let utf16Length: Int

    public init(lineIndex: Int, utf16Offset: Int, utf16Length: Int) {
        self.lineIndex = lineIndex
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }
}

public struct KaraokeWordCue: Equatable, Sendable {
    public let startTimeMs: Int
    public let endTimeMs: Int
    public let highlight: LiveWordHighlight

    public init(startTimeMs: Int, endTimeMs: Int, highlight: LiveWordHighlight) {
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.highlight = highlight
    }
}

/// Builds a stable word clock from synchronized lyrics. Provider-supplied
/// syllable timing is preferred. A line without word timing is divided using
/// word-length and punctuation weights, which is deliberately deterministic:
/// mixed music is a much poorer timing source than the synchronized line itself.
public struct KaraokeWordTimeline: Sendable {
    public let cues: [KaraokeWordCue]
    public let usesProviderWordTiming: Bool

    public init(lyrics: Lyrics) {
        var builtCues: [KaraokeWordCue] = []
        var usedProviderTiming = false

        for (lineIndex, line) in lyrics.lines.enumerated() {
            let tokens = Self.tokens(in: line.words)
            guard !tokens.isEmpty, line.endTimeMs > line.startTimeMs else { continue }

            let starts: [Int]
            if let providerStarts = Self.providerStarts(for: tokens, in: line) {
                starts = providerStarts
                usedProviderTiming = true
            } else {
                starts = Self.estimatedStarts(for: tokens, in: line)
            }

            for (wordIndex, token) in tokens.enumerated() {
                let end = wordIndex + 1 < starts.count
                    ? starts[wordIndex + 1]
                    : line.endTimeMs
                builtCues.append(
                    KaraokeWordCue(
                        startTimeMs: starts[wordIndex],
                        endTimeMs: max(end, starts[wordIndex] + 1),
                        highlight: LiveWordHighlight(
                            lineIndex: lineIndex,
                            utf16Offset: token.range.location,
                            utf16Length: token.range.length
                        )
                    )
                )
            }
        }

        cues = builtCues.sorted { $0.startTimeMs < $1.startTimeMs }
        usesProviderWordTiming = usedProviderTiming
    }

    public func highlight(at positionMs: Int) -> LiveWordHighlight? {
        cue(at: positionMs)?.highlight
    }

    public func nextTransitionTime(after positionMs: Int) -> Int? {
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].startTimeMs <= positionMs {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return cues.indices.contains(low) ? cues[low].startTimeMs : nil
    }

    private func cue(at positionMs: Int) -> KaraokeWordCue? {
        guard !cues.isEmpty else { return nil }
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].startTimeMs <= positionMs {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low - 1
        guard cues.indices.contains(index), positionMs < cues[index].endTimeMs else { return nil }
        return cues[index]
    }

    private struct Token {
        let range: NSRange
        let characterOffset: Int
        let weight: Double
    }

    private static func tokens(in string: String) -> [Token] {
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = wordExpression.matches(in: string, range: fullRange)
        return matches.enumerated().compactMap { index, match in
            guard let swiftRange = Range(match.range, in: string) else { return nil }
            let characterOffset = string.distance(
                from: string.startIndex,
                to: swiftRange.lowerBound
            )
            let length = max(string.distance(from: swiftRange.lowerBound, to: swiftRange.upperBound), 1)
            let nextLocation = index + 1 < matches.count
                ? matches[index + 1].range.location
                : nsString.length
            let trailingRange = NSRange(
                location: NSMaxRange(match.range),
                length: max(nextLocation - NSMaxRange(match.range), 0)
            )
            let trailing = nsString.substring(with: trailingRange)
            let punctuationPause = trailing.range(of: #"[,.;:!?…]"#, options: .regularExpression) == nil
                ? 0
                : 0.55
            return Token(
                range: match.range,
                characterOffset: characterOffset,
                weight: 1 + log2(Double(min(length, 12))) + punctuationPause
            )
        }
    }

    private static func providerStarts(
        for tokens: [Token],
        in line: LyricLine
    ) -> [Int]? {
        guard !line.syllables.isEmpty else { return nil }
        var syllableEnds: [(endOffset: Int, startTimeMs: Int)] = []
        var characterCursor = 0
        for syllable in line.syllables where syllable.count > 0 {
            characterCursor += syllable.count
            syllableEnds.append((characterCursor, syllable.startTimeMs))
        }
        guard !syllableEnds.isEmpty else { return nil }

        var starts: [Int] = []
        for token in tokens {
            guard let syllable = syllableEnds.first(where: {
                $0.endOffset > token.characterOffset
            }) else {
                return nil
            }
            let minimum = (starts.last ?? (line.startTimeMs - 1)) + 1
            starts.append(min(max(syllable.startTimeMs, minimum), line.endTimeMs - 1))
        }
        return starts
    }

    private static func estimatedStarts(
        for tokens: [Token],
        in line: LyricLine
    ) -> [Int] {
        let duration = Double(max(line.endTimeMs - line.startTimeMs, tokens.count))
        let totalWeight = max(tokens.reduce(0) { $0 + $1.weight }, 1)
        var elapsedWeight = 0.0
        return tokens.map { token in
            defer { elapsedWeight += token.weight }
            return line.startTimeMs + Int(duration * elapsedWeight / totalWeight)
        }
    }

    private static let wordExpression = try! NSRegularExpression(
        pattern: #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#
    )
}
