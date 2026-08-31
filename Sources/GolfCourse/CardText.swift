import Foundation

/// Reducing a fetched course page to the text a scorecard extractor can read.
///
/// Lives beside `CourseCard` rather than in the CLI because it is the only
/// site-shaped code in the import path *and* the part most likely to be wrong in a
/// way nobody notices — so it needs tests, and an executable target cannot have
/// them.
public enum CardText {

    /// Tags out, entities in, **table shape kept**.
    ///
    /// Three details are load-bearing, all three found on a real published card
    /// (angelesnational.com):
    ///
    /// 1. **The source's own whitespace is flattened first.** A raw newline between
    ///    `</td>` and `<td>` would otherwise survive as a row break and hide the
    ///    cell boundary behind it.
    /// 2. **Inline tags are deleted, not replaced with a space.** That card's men's
    ///    stroke index for hole 4 is `1<span class="style1">7</span>`. Substituting
    ///    a space turns it into `1 7` — a plausible-looking pair of stroke indexes
    ///    that is really the number 17, and a shifted handicap column still passes
    ///    the 1…18 permutation check often enough to ship.
    /// 3. **Cell and row boundaries survive as tabs and newlines.** Without them a
    ///    handicap row is a stream of digits and an empty cell is invisible — and
    ///    the columns are exactly what the reconciliation checks.
    public static func strip(_ html: String) -> String {
        var s = html
        for pattern in ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>",
                        "<!--[\\s\\S]*?-->", "<head[^>]*>[\\s\\S]*?</head>"] {
            s = s.replacingOccurrences(of: pattern, with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }

        // (1) HTML treats its own whitespace as insignificant. So must we, first.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // (3) Structure, while the tags that carry it still exist.
        s = s.replacingOccurrences(of: "</(td|th)>", with: "\t",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(tr|table|div|p|h[1-6]|li)>|<br\\s*/?>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])

        // (2) Everything left is inline. Delete it — never substitute a space.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)

        // Collapse runs of spaces only; tabs and newlines are the table's shape.
        s = s.replacingOccurrences(of: "[^\\S\t\n]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ?\t ?", with: "\t", options: .regularExpression)
        s = s.replacingOccurrences(of: " ?\n ?", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Named and numeric HTML entities.
    ///
    /// Numeric matters more than it sounds: `&#8217;` is the apostrophe in
    /// `Men&#8217;s Hcp`, and a card whose row *labels* are mangled is a card whose
    /// columns the model has to guess at.
    public static func decodeEntities(_ input: String) -> String {
        var s = input
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                               "&quot;": "\"", "&apos;": "'", "&hellip;": "…",
                               "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
                               "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
                               "&ndash;": "–", "&mdash;": "—"] {
            s = s.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
        }
        guard s.contains("&#") else { return s }

        var out = ""
        var i = s.startIndex
        while let amp = s[i...].range(of: "&#") {
            out += s[i..<amp.lowerBound]
            // A real numeric entity is short. Bounding the search stops an
            // unterminated `&#` from swallowing everything up to the next
            // semicolon somewhere else on the page.
            let window = s[amp.upperBound...].prefix(9)
            guard let semi = window.firstIndex(of: ";"),
                  case let body = window[window.startIndex..<semi],
                  !body.isEmpty else {
                // Not an entity. Emit the `&#` and carry on *past* it, so the
                // scan cannot rediscover the same spot forever.
                out += s[amp.lowerBound..<amp.upperBound]
                i = amp.upperBound
                continue
            }
            let isHex = body.first == "x" || body.first == "X"
            let digits = isHex ? body.dropFirst() : body[...]
            if !digits.isEmpty,
               let code = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            } else {
                out += s[amp.lowerBound...semi]   // not an entity; leave it alone
            }
            i = s.index(after: semi)
        }
        out += s[i...]
        return out
    }
}
