import Foundation

@main struct EmbeddedDraftTests {
    static func main() {
        let draft = EmbeddedDraft("前\u{FFFC}中\u{FFFC}后")
        assert(draft.modelText == "前<object id=\"1\">中<object id=\"2\">后")
        assert(draft.textRanges == [NSRange(location: 0, length: 1),
                                     NSRange(location: 2, length: 1),
                                     NSRange(location: 4, length: 1)])
        let restored = draft.restore("开头<object id=\"1\">中间<object id=\"2\">结尾")
        assert(restored?.text == "开头\u{FFFC}中间\u{FFFC}结尾")
        assert(restored?.segments == ["开头", "中间", "结尾"])
        assert(draft.restore("开头<object id=\"2\">中间<object id=\"1\">结尾") == nil)
        assert(draft.restore("开头<object id=\"1\">结尾") == nil)
        assert(draft.restore("开头<object id=\"1\">中间<object id=\"2\">结尾<object id=\"2\">") == nil)
        assert(draft.restore("开头\u{FFFC}<object id=\"1\">中间<object id=\"2\">结尾") == nil)

        let literal = EmbeddedDraft("<object id=\"1\">\u{FFFC}后")
        assert(!literal.markers[0].isEmpty && literal.markers[0] != "<object id=\"1\">")
        assert(literal.markers == EmbeddedDraft(literal.original).markers)
        assert(literal.restore(literal.modelText)?.text == literal.original)
        assert(literal.restore(literal.modelText + "<object id=\"99\">") == nil)
        let emoji = EmbeddedDraft("😀\u{FFFC}后")
        assert(emoji.textRanges == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 1)])
        assert(EmbeddedDraft("\u{FFFC}\n").segments.allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        assert(EmbeddedDraft("普通文本").restore("改写")?.text == "改写")
        print("EmbeddedDraft tests passed")
    }
}
