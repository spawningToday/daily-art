import Foundation

/// Converts the museum's lightly HTML-formatted text into styled plain text.
///
/// This is a *formatting* step only: words are never added, removed, or rephrased.
/// Tags are dropped (keeping `<em>`/`<i>` as italics and `<br>`/`<p>` as line breaks),
/// entities are decoded, and whitespace is normalized.
enum MuseumTextFormatter {
    static func runs(fromHTML html: String) -> [TextRun] {
        let containsMarkup = html.range(of: "<[A-Za-z/!][^>]*>", options: .regularExpression) != nil
        var chars: [(Character, Bool)] = []
        var italicDepth = 0

        func append(_ text: String) {
            let decoded = decodeEntities(text)
            for ch in decoded {
                var c = ch
                if ch == "\r\n" || ch == "\r" || ch == "\n" {
                    // Raw newlines inside HTML are just whitespace; in plain text they are breaks.
                    c = containsMarkup ? " " : "\n"
                } else if ch == "\t" || ch == "\u{00A0}" {
                    c = " "
                }
                chars.append((c, italicDepth > 0))
            }
        }

        var index = html.startIndex
        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                append(String(html[index...]))
                break
            }
            append(String(html[index..<open]))
            if html[open...].hasPrefix("<!--") {
                if let end = html[open...].range(of: "-->") {
                    index = end.upperBound
                } else {
                    index = html.endIndex
                }
                continue
            }
            guard let close = html[open...].firstIndex(of: ">") else {
                // A lone "<" is literal text (e.g. "< 1 cm").
                append(String(html[open...]))
                break
            }
            let tag = html[html.index(after: open)..<close]
            let isClosing = tag.hasPrefix("/")
            let name = tag
                .drop(while: { $0 == "/" })
                .prefix(while: { $0.isLetter || $0.isNumber })
                .lowercased()
            if name.isEmpty {
                // Not a tag after all ("a < b > c"); keep it verbatim.
                append(String(html[open...close]))
            } else {
                switch name {
                case "em", "i", "cite":
                    italicDepth = max(0, italicDepth + (isClosing ? -1 : 1))
                case "br":
                    chars.append(("\n", false))
                case "p", "div", "blockquote":
                    chars.append(("\n", false))
                    chars.append(("\n", false))
                case "li":
                    if !isClosing { chars.append(("\n", false)); chars.append(("•", false)); chars.append((" ", false)) }
                default:
                    break
                }
            }
            index = html.index(after: close)
        }
        return group(normalize(chars))
    }

    static func plainText(fromHTML html: String) -> String {
        runs(fromHTML: html).map(\.text).joined()
    }

    // MARK: - Whitespace

    private static func normalize(_ input: [(Character, Bool)]) -> [(Character, Bool)] {
        var out: [(Character, Bool)] = []
        out.reserveCapacity(input.count)
        for (ch, italic) in input {
            if ch == " " {
                // Collapse runs of spaces and drop spaces at line starts.
                if let last = out.last, last.0 == " " || last.0 == "\n" { continue }
                if out.isEmpty { continue }
                out.append((ch, italic))
            } else if ch == "\n" {
                // Drop trailing spaces before a newline; allow at most one blank line.
                while let last = out.last, last.0 == " " { out.removeLast() }
                if out.isEmpty { continue }
                let trailingNewlines = out.reversed().prefix(while: { $0.0 == "\n" }).count
                if trailingNewlines >= 2 { continue }
                out.append((ch, false))
            } else {
                out.append((ch, italic))
            }
        }
        while let last = out.last, last.0 == " " || last.0 == "\n" { out.removeLast() }
        return out
    }

    private static func group(_ chars: [(Character, Bool)]) -> [TextRun] {
        var runs: [TextRun] = []
        for (ch, italic) in chars {
            // Spaces adopt the style of the run they're in to avoid fragmenting runs.
            if var last = runs.last, last.isItalic == italic || ch == " " {
                last.text.append(ch)
                runs[runs.count - 1] = last
            } else {
                runs.append(TextRun(text: String(ch), isItalic: italic))
            }
        }
        return runs
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "hellip": "\u{2026}", "middot": "\u{00B7}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "deg": "\u{00B0}", "frac12": "\u{00BD}",
        "frac14": "\u{00BC}", "frac34": "\u{00BE}", "times": "\u{00D7}", "laquo": "\u{00AB}",
        "raquo": "\u{00BB}", "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë",
        "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "aring": "å", "atilde": "ã",
        "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï", "oacute": "ó", "ograve": "ò",
        "ocirc": "ô", "ouml": "ö", "otilde": "õ", "oslash": "ø", "uacute": "ú", "ugrave": "ù",
        "ucirc": "û", "uuml": "ü", "ccedil": "ç", "ntilde": "ñ", "szlig": "ß", "aelig": "æ",
        "oelig": "œ", "Eacute": "É", "Agrave": "À", "Ccedil": "Ç", "Ouml": "Ö", "Uuml": "Ü",
        "Auml": "Ä", "shy": "",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            guard ch == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";")
            else {
                result.append(ch)
                index = text.index(after: index)
                continue
            }
            let entity = String(text[text.index(after: index)..<semicolon])
            if let replacement = decodeEntity(entity) {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(ch)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let body = entity.dropFirst()
            let scalarValue: UInt32?
            if body.first == "x" || body.first == "X" {
                scalarValue = UInt32(body.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(body, radix: 10)
            }
            guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[entity]
    }
}
