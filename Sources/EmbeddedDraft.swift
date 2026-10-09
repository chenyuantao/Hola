import Foundation

/// AXValue only exposes the position of an embedded object, not its underlying data.
struct EmbeddedDraft {
    static let objectCharacter: Character = "\u{FFFC}"

    let original: String
    let segments: [String]
    let markers: [String]

    init(_ original: String) {
        self.original = original
        segments = original.split(separator: Self.objectCharacter, omittingEmptySubsequences: false).map(String.init)
        let count = segments.count - 1
        var candidate: [String] = []
        if count > 0 {
            var firstID = 1
            repeat {
                candidate = (firstID..<(firstID + count)).map { "<object id=\"\($0)\">" }
                firstID += 1
            } while candidate.contains(where: original.contains)
        }
        markers = candidate
    }

    var hasObjects: Bool { !markers.isEmpty }

    var modelText: String {
        guard hasObjects else { return original }
        return segments.enumerated().map { index, segment in
            index < markers.count ? segment + markers[index] : segment
        }.joined()
    }

    var instruction: String {
        L("文本中的 <object id=\"…\"> 是嵌入对象的占位符。请保留每个占位符的原文、数量和顺序，只处理占位符之间的普通文字；不要删除、移动或改写占位符。")
    }

    private func literalObjectTags(in text: String) -> [String] {
        let pattern = #"<object id="[^"]+">"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
    }

    /// Returns the revised plain text and its spans around the unchanged objects.
    func restore(_ response: String) -> (text: String, segments: [String])? {
        guard hasObjects else { return (response, [response]) }
        var remaining = response[...]
        var revised: [String] = []
        for marker in markers {
            guard let range = remaining.range(of: marker) else { return nil }
            let segment = String(remaining[..<range.lowerBound])
            guard !segment.contains(Self.objectCharacter),
                  literalObjectTags(in: segment) == literalObjectTags(in: segments[revised.count]) else { return nil }
            revised.append(segment)
            remaining = remaining[range.upperBound...]
        }
        let last = String(remaining)
        guard !last.contains(Self.objectCharacter),
              literalObjectTags(in: last) == literalObjectTags(in: segments[revised.count]) else { return nil }
        revised.append(last)
        let text = revised.enumerated().map { index, segment in
            index < markers.count ? segment + String(Self.objectCharacter) : segment
        }.joined()
        return (text, revised)
    }

    var textRanges: [NSRange] {
        var location = 0
        return segments.enumerated().map { index, segment in
            let range = NSRange(location: location, length: segment.utf16.count)
            location += range.length + (index < markers.count ? 1 : 0)
            return range
        }
    }
}
