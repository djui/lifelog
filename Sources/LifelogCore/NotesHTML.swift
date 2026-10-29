import Foundation

/// A local HTML-to-Markdown converter. It never loads images, styles, or links.
public enum NotesHTML {
    public static func markdown(from html: String) -> String {
        let root = Parser.parse(omitEmbeddedMedia(html))
        return render(root).replacingOccurrences(of: "\n[ \t]+\n", with: "\n\n",
                                                options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drop inlined media so huge `data:` URIs never reach the parser or Markdown files.
    static func omitEmbeddedMedia(_ html: String) -> String {
        var result = replace(imgTag, in: html) { tag in
            let alt = imageAlt(tag).flatMap { $0.isEmpty ? nil : $0 } ?? "Image"
            return "<img alt=\"\(alt.replacingOccurrences(of: "\"", with: ""))\">"
        }
        result = replace(objectBlock, in: result) { _ in "<object></object>" }
        result = replace(objectOrEmbedOpen, in: result) { _ in "<object></object>" }
        result = replace(dataAttribute, in: result) { _ in "" }
        return result
    }

    private static let imgTag = try! NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
    private static let objectBlock = try! NSRegularExpression(pattern: #"<(object|embed)\b[^>]*>[\s\S]*?</\1>"#, options: [.caseInsensitive])
    private static let objectOrEmbedOpen = try! NSRegularExpression(pattern: #"<(?:embed\b[^>]*|object\s[^>]*)/?>"#, options: [.caseInsensitive])
    private static let dataAttribute = try! NSRegularExpression(pattern: #"\s(?:src|href|data)\s*=\s*["']data:[^"']*["']"#, options: [.caseInsensitive])
    private static let altAttribute = try! NSRegularExpression(pattern: #"\balt\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])

    private static func replace(_ regex: NSRegularExpression, in html: String, with replacement: (String) -> String) -> String {
        let source = html as NSString
        let result = NSMutableString(string: html)
        for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
            result.replaceCharacters(in: match.range, with: replacement(source.substring(with: match.range)))
        }
        return result as String
    }

    private static func imageAlt(_ tag: String) -> String? {
        let source = tag as NSString
        guard let match = altAttribute.firstMatch(in: tag, range: NSRange(location: 0, length: source.length)) else { return nil }
        for index in 1..<match.numberOfRanges {
            let range = match.range(at: index)
            if range.location != NSNotFound, range.length > 0 { return source.substring(with: range) }
        }
        return nil
    }

    private final class Node {
        let tag: String
        let attributes: [String: String]
        let text: String
        var children: [Node] = []

        init(tag: String = "", attributes: [String: String] = [:], text: String = "") {
            self.tag = tag
            self.attributes = attributes
            self.text = text
        }
    }

    private enum Parser {
        // Quotes are included in a token, so an attribute containing ">" cannot
        // accidentally become visible note text.
        static let tokens = try! NSRegularExpression(
            pattern: #"<!--[\s\S]*?-->|<![^>]*>|</?[A-Za-z](?:[^>"']|"[^"]*"|'[^']*')*>|[^<]+|<"#)
        static let attributes = try! NSRegularExpression(
            pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?"#)
        static let voidTags: Set<String> = ["br", "hr", "img", "input", "meta", "link", "wbr", "area", "base", "col", "embed", "param", "source", "track"]

        static func parse(_ html: String) -> Node {
            let root = Node(tag: "root")
            var stack = [root]
            let source = html as NSString
            for match in tokens.matches(in: html, range: NSRange(location: 0, length: source.length)) {
                let token = source.substring(with: match.range)
                guard token.hasPrefix("<"), token != "<" else {
                    stack.last?.children.append(Node(text: token))
                    continue
                }
                if token.hasPrefix("<!") { continue }
                let closing = token.hasPrefix("</")
                let interior = String(token.dropFirst(closing ? 2 : 1).dropLast())
                let name = interior.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }.lowercased()
                if closing {
                    if let index = stack.lastIndex(where: { $0.tag == name }), index > 0 {
                        stack.removeSubrange(index...)
                    }
                    continue
                }
                // Common optional closing tags in HTML, including pasted tables.
                if ["li", "p", "tr", "td", "th"].contains(name), stack.last?.tag == name {
                    stack.removeLast()
                }
                var values: [String: String] = [:]
                let attributeText = String(interior.dropFirst(name.count)) as NSString
                for attribute in attributes.matches(in: attributeText as String,
                                                     range: NSRange(location: 0, length: attributeText.length)) {
                    let key = attributeText.substring(with: attribute.range(at: 1)).lowercased()
                    let valueRange = (2...4).map { attribute.range(at: $0) }.first { $0.location != NSNotFound }
                    values[key] = valueRange.map { decodeEntities(attributeText.substring(with: $0)) } ?? ""
                }
                let node = Node(tag: name, attributes: values)
                stack.last?.children.append(node)
                if !voidTags.contains(name), !token.hasSuffix("/>") { stack.append(node) }
            }
            return root
        }
    }

    private static func render(_ node: Node) -> String {
        if node.tag.isEmpty {
            return escape(decodeEntities(node.text)
                .replacingOccurrences(of: "[\\s\\u00a0]+", with: " ", options: .regularExpression))
        }
        if ["script", "style", "head", "title", "template"].contains(node.tag) { return "" }
        let content = node.children.map(render).joined()
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch node.tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(node.tag.dropFirst()) ?? 1
            return "\n\n" + String(repeating: "#", count: level) + " " + trimmed + "\n\n"
        case "p", "div", "section", "article", "header", "footer":
            return trimmed.isEmpty ? "\n\n" : "\n\n" + trimmed + "\n\n"
        case "br": return "\n"
        case "hr": return "\n\n---\n\n"
        case "strong", "b": return wrap(trimmed, with: "**")
        case "em", "i": return wrap(trimmed, with: "*")
        case "s", "strike", "del": return wrap(trimmed, with: "~~")
        case "code", "tt":
            let text = plainText(node).trimmingCharacters(in: .whitespacesAndNewlines)
            let delimiter = String(repeating: "`", count: longestBacktickRun(text) + 1)
            let padding = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
            return delimiter + padding + text + padding + delimiter
        case "pre":
            let text = plainText(node).trimmingCharacters(in: .newlines)
            let fence = String(repeating: "`", count: max(3, longestBacktickRun(text) + 1))
            return "\n\n" + fence + "\n" + text + "\n" + fence + "\n\n"
        case "blockquote":
            return "\n\n" + trimmed.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        case "ul", "ol": return "\n\n" + renderList(node, depth: 0) + "\n\n"
        case "li": return "\n- " + trimmed + "\n"
        case "a":
            guard let destination = node.attributes["href"], let safe = linkDestination(destination) else { return content }
            return "[" + (trimmed.isEmpty ? escape(destination) : trimmed) + "](" + safe + ")"
        case "img":
            let label = node.attributes["alt"].flatMap { $0.isEmpty ? nil : $0 } ?? "Image"
            // Assets are not fetched or copied; retain useful, inert alt text.
            return "[" + escape(label) + "]"
        case "object", "embed": return trimmed.isEmpty ? "[Attachment]" : content
        case "input":
            guard node.attributes["type"]?.lowercased() == "checkbox" else { return "" }
            return node.attributes["checked"] == nil ? "[ ] " : "[x] "
        case "table": return "\n\n" + renderTable(node) + "\n\n"
        default: return content
        }
    }

    private static func renderList(_ node: Node, depth: Int) -> String {
        var lines: [String] = []
        var number = Int(node.attributes["start"] ?? "1") ?? 1
        for child in node.children {
            guard child.tag == "li" else {
                let extra = render(child).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extra.isEmpty { lines.append(extra) }
                continue
            }
            if let value = child.attributes["value"].flatMap(Int.init) { number = value }
            let marker = node.tag == "ol" ? "\(number). " : "- "
            let indentation = String(repeating: "    ", count: depth)
            var buffer = ""
            var first = true
            func flush() {
                let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty || first else { buffer = ""; return }
                let parts = text.components(separatedBy: "\n")
                for (index, part) in parts.enumerated() {
                    let prefix = first && index == 0 ? marker : String(repeating: " ", count: marker.count)
                    lines.append(indentation + prefix + part)
                }
                first = false
                buffer = ""
            }
            for item in child.children {
                if item.tag == "ul" || item.tag == "ol" {
                    flush()
                    lines.append(renderList(item, depth: depth + 1))
                } else {
                    buffer += render(item)
                }
            }
            flush()
            number += 1
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTable(_ node: Node) -> String {
        var rows: [[String]] = []
        func collect(_ current: Node) {
            if current.tag == "tr" {
                rows.append(current.children.filter { $0.tag == "td" || $0.tag == "th" }.map {
                    $0.children.map(render).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n+", with: "<br>", options: .regularExpression)
                })
            } else if current.tag != "table" || current === node {
                current.children.forEach(collect)
            }
        }
        collect(node)
        guard let width = rows.map(\.count).max(), width > 0 else { return plainText(node) }
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        func row(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        var output = [row(padded[0]), row(Array(repeating: "---", count: width))]
        output.append(contentsOf: padded.dropFirst().map(row))
        return output.joined(separator: "\n")
    }

    private static func plainText(_ node: Node) -> String {
        if node.tag.isEmpty { return decodeEntities(node.text) }
        if node.tag == "br" { return "\n" }
        if ["script", "style", "head", "template"].contains(node.tag) { return "" }
        return node.children.map(plainText).joined()
    }

    private static func wrap(_ text: String, with delimiter: String) -> String {
        text.isEmpty ? "" : delimiter + text + delimiter
    }

    private static func escape(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]", "<", ">", "#"] {
            value = value.replacingOccurrences(of: character, with: "\\" + character)
        }
        return value
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    private static func linkDestination(_ raw: String) -> String? {
        let destination = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if let colon = destination.firstIndex(of: ":") {
            let scheme = destination[..<colon].lowercased()
            guard ["https", "http", "mailto", "tel", "notes", "applenotes"].contains(scheme) else { return nil }
        }
        return destination.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: "\\", with: "%5C")
    }

    private static let entityPattern = try! NSRegularExpression(pattern: #"&(#(?:[xX][0-9A-Fa-f]+|[0-9]+)|[A-Za-z][A-Za-z0-9]+);"#)
    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}",
        "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "hellip": "…", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "times": "×", "divide": "÷",
        "laquo": "«", "raquo": "»", "auml": "ä", "ouml": "ö", "uuml": "ü", "Aring": "Å", "aring": "å",
        "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "Eacute": "É"
    ]

    private static func decodeEntities(_ text: String) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in entityPattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = source.substring(with: match.range(at: 1))
            let replacement: String?
            if name.hasPrefix("#") {
                let hex = name.dropFirst().hasPrefix("x") || name.dropFirst().hasPrefix("X")
                let digits = name.dropFirst(hex ? 2 : 1)
                replacement = UInt32(digits, radix: hex ? 16 : 10).flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = entities[name]
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}
