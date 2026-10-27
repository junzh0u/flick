import Foundation

/// Flick's settings, kept in a TOML file — `$XDG_CONFIG_HOME/flick/config.toml`,
/// else `~/.config/flick/config.toml` — so they can be synced and versioned
/// with other dotfiles. Missing keys take their defaults and unknown ones are
/// ignored, so the file may hold only what differs; out-of-range values are
/// clamped.
///
/// The file is read with a small parser for the flat subset of TOML these
/// settings need: bare keys, numbers, booleans, strings and arrays of strings,
/// with comments. Writing changes back rewrites only the lines of keys whose
/// values changed, so the file's comments and layout survive.
public struct FlickSettings: Equatable, Sendable {
    /// Finger travel, in scroll points, a swipe needs.
    public var swipeThreshold = 50.0
    /// Seconds a window eases into place; 0 jumps.
    public var animationDuration = 0.2
    public var showPreviews = true
    public var keepPointerOnTitleBar = true
    /// Bundle identifiers of apps whose windows Flick leaves alone.
    public var excludedApps: [String] = []

    public static let swipeThresholds: ClosedRange<Double> = 10...200
    public static let animationDurations: ClosedRange<Double> = 0...1

    public init() {}

    /// The settings with every value in range.
    public func clamped() -> FlickSettings {
        var s = self
        s.swipeThreshold = min(max(s.swipeThreshold, Self.swipeThresholds.lowerBound),
                               Self.swipeThresholds.upperBound)
        s.animationDuration = min(max(s.animationDuration, Self.animationDurations.lowerBound),
                                  Self.animationDurations.upperBound)
        return s
    }

    /// Where the settings live, for `environment` (the process's by default).
    public static func fileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("flick/config.toml")
    }

    /// The settings in the file, or the defaults when it is missing or invalid.
    public static func load(from url: URL = fileURL()) -> FlickSettings {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? decode(toml: $0) }
            ?? FlickSettings()
    }

    public static func decode(toml text: String) throws(SettingsError) -> FlickSettings {
        var settings = FlickSettings()
        for entry in try TOML.parse(text) {
            guard let key = Key(rawValue: entry.key) else { continue }
            try settings.set(key, entry.value, line: entry.lines.lowerBound + 1)
        }
        return settings.clamped()
    }

    /// `text` — the file as it is, nil when there is none yet — with these
    /// settings written in. Keys whose values changed have their lines
    /// rewritten in place, keeping any comment after them; keys the file lacks
    /// are appended when they differ from the default. A new file starts from
    /// a commented template listing every key. Throws when `text` doesn't
    /// parse, rather than guess at it.
    public func toml(updating text: String?) throws(SettingsError) -> String {
        var lines = (text ?? Self.template).components(separatedBy: "\n")
        let entries = try TOML.parse(lines.joined(separator: "\n"))
        var appended: [String] = []
        // Bottom up, so earlier entries' line ranges stay put.
        for entry in entries.reversed() {
            guard let key = Key(rawValue: entry.key), entry.value != value(key) else { continue }
            let rewritten = entry.indent + key.rawValue + " = " + TOML.format(value(key), indent: entry.indent)
                + entry.trailer
            lines.replaceSubrange(entry.lines, with: rewritten.components(separatedBy: "\n"))
        }
        let present = Set(entries.map(\.key))
        for key in Key.allCases where !present.contains(key.rawValue)
            && value(key) != FlickSettings().value(key) {
            appended.append(key.rawValue + " = " + TOML.format(value(key), indent: ""))
        }
        if !appended.isEmpty {
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines += appended
        }
        if lines.last?.isEmpty != true { lines.append("") }
        return lines.joined(separator: "\n")
    }

    /// The file's keys, in the order a new file lists them.
    enum Key: String, CaseIterable {
        case swipeThreshold = "swipe_threshold"
        case animationDuration = "animation_duration"
        case showPreviews = "show_previews"
        case keepPointerOnTitleBar = "keep_pointer_on_title_bar"
        case excludedApps = "excluded_apps"

        var comment: String {
            switch self {
            case .swipeThreshold: "Finger travel, in scroll points, a swipe needs (10–200)."
            case .animationDuration: "Seconds a window eases into place; 0 jumps (0–1)."
            case .showPreviews: "Show where a gesture will put the window while it's in progress."
            case .keepPointerOnTitleBar:
                "After a swipe moves a window, move the pointer back onto its title bar."
            case .excludedApps:
                "Bundle identifiers of apps whose windows gestures pass through, e.g.\n# \"com.apple.finder\"."
            }
        }
    }

    static var template: String {
        let defaults = FlickSettings()
        return """
            # Flick settings, reloaded whenever this file changes. Keys left out take
            # their defaults. See https://github.com/junzh0u/flick#settings

            """ + Key.allCases.map { key in
                "\n# \(key.comment)\n\(key.rawValue) = \(TOML.format(defaults.value(key), indent: ""))\n"
            }.joined()
    }

    func value(_ key: Key) -> TOML.Value {
        switch key {
        case .swipeThreshold: .number(swipeThreshold)
        case .animationDuration: .number(animationDuration)
        case .showPreviews: .bool(showPreviews)
        case .keepPointerOnTitleBar: .bool(keepPointerOnTitleBar)
        case .excludedApps: .array(excludedApps.map(TOML.Value.string))
        }
    }

    mutating func set(_ key: Key, _ value: TOML.Value, line: Int) throws(SettingsError) {
        func wrong(_ expected: String) -> SettingsError {
            SettingsError(line: line, message: "\(key.rawValue) should be \(expected)")
        }
        switch (key, value) {
        case (.swipeThreshold, .number(let n)): swipeThreshold = n
        case (.animationDuration, .number(let n)): animationDuration = n
        case (.showPreviews, .bool(let b)): showPreviews = b
        case (.keepPointerOnTitleBar, .bool(let b)): keepPointerOnTitleBar = b
        case (.excludedApps, .array(let items)):
            excludedApps = try items.map { item throws(SettingsError) in
                guard case .string(let s) = item else { throw wrong("an array of strings") }
                return s
            }
        case (.swipeThreshold, _), (.animationDuration, _): throw wrong("a number")
        case (.showPreviews, _), (.keepPointerOnTitleBar, _): throw wrong("true or false")
        case (.excludedApps, _): throw wrong("an array of strings")
        }
    }
}

public struct SettingsError: Error, Equatable, CustomStringConvertible, Sendable {
    public let line: Int
    public let message: String

    public var description: String { "line \(line): \(message)" }
}

/// The flat subset of TOML the settings use.
enum TOML {
    indirect enum Value: Equatable, Sendable {
        case number(Double)
        case bool(Bool)
        case string(String)
        case array([Value])
    }

    struct Entry {
        let key: String
        let value: Value
        /// The lines it spans, 0-based; more than one for a multi-line array.
        let lines: Range<Int>
        let indent: String
        /// What follows the value on its last line: spacing and a comment.
        let trailer: String
    }

    static func parse(_ text: String) throws(SettingsError) -> [Entry] {
        let lines = text.components(separatedBy: "\n")
        var entries: [Entry] = []
        var seen = Set<String>()
        var i = 0
        while i < lines.count {
            let (code, _) = splitComment(lines[i])
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                i += 1
                continue
            }
            func fail(_ message: String) -> SettingsError { SettingsError(line: i + 1, message: message) }
            if trimmed.hasPrefix("[") { throw fail("tables aren't supported") }
            guard let equals = trimmed.firstIndex(of: "=") else { throw fail("expected key = value") }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            else { throw fail("expected a bare key before =") }
            guard seen.insert(key).inserted else { throw fail("\(key) is set twice") }
            var valueText = String(trimmed[trimmed.index(after: equals)...])
            var end = i
            while depth(valueText) > 0 {
                end += 1
                guard end < lines.count else { throw fail("unclosed [") }
                valueText += "\n" + splitComment(lines[end]).code
            }
            let (lastCode, comment) = splitComment(lines[end])
            let gap = String(lastCode.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            let value: Value
            do {
                value = try parseValue(valueText.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                throw fail("\(key): \(error.message)")
            }
            entries.append(Entry(
                key: key, value: value, lines: i..<(end + 1),
                indent: String(lines[i].prefix { $0 == " " || $0 == "\t" }),
                trailer: comment.map { gap + $0 } ?? ""))
            i = end + 1
        }
        return entries
    }

    static func format(_ value: Value, indent: String) -> String {
        switch value {
        case .number(let n):
            n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b):
            String(b)
        case .string(let s):
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .array(let items) where items.count <= 1:
            "[" + items.map { format($0, indent: indent) }.joined(separator: ", ") + "]"
        case .array(let items):
            "[\n" + items.map { indent + "  " + format($0, indent: indent) + ",\n" }.joined() + indent + "]"
        }
    }

    private struct ValueError: Error {
        let message: String
    }

    private static func parseValue(_ text: String) throws(ValueError) -> Value {
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            guard let (string, rest) = parseString(text[...]), rest.isEmpty else {
                throw ValueError(message: "malformed string")
            }
            return .string(string)
        }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw ValueError(message: "malformed array") }
            return .array(try splitItems(String(text.dropFirst().dropLast())).map(parseValue))
        }
        let digits = text.replacingOccurrences(of: "_", with: "")
        guard let n = Double(digits), n.isFinite, !digits.contains(where: { $0.isLetter && $0 != "e" && $0 != "E" })
        else { throw ValueError(message: text.isEmpty ? "missing value" : "unrecognized value \(text)") }
        return .number(n)
    }

    /// A string at the start of `text`, unescaped, and what follows it.
    private static func parseString(_ text: Substring) -> (String, Substring)? {
        guard let quote = text.first else { return nil }
        var result = ""
        var i = text.index(after: text.startIndex)
        while i < text.endIndex {
            let c = text[i]
            if c == quote {
                return (result, text[text.index(after: i)...].drop { $0 == " " || $0 == "\t" })
            }
            if c == "\\" && quote == "\"" {
                i = text.index(after: i)
                guard i < text.endIndex else { return nil }
                switch text[i] {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"", "\\": result.append(text[i])
                default: return nil
                }
            } else if c == "\n" {
                return nil
            } else {
                result.append(c)
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// An array's items, split at top-level commas; a trailing comma is fine.
    private static func splitItems(_ text: String) throws(ValueError) -> [String] {
        var items: [String] = []
        var current = ""
        var nesting = 0
        var quote: Character?
        var escaped = false
        for c in text {
            if let q = quote {
                current.append(c)
                if escaped { escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'": quote = c; current.append(c)
            case "[": nesting += 1; current.append(c)
            case "]": nesting -= 1; current.append(c)
            case "," where nesting == 0:
                let item = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.isEmpty else { throw ValueError(message: "empty array item") }
                items.append(item)
                current = ""
            default: current.append(c)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { items.append(last) }
        return items
    }

    /// How many more [ than ] `text` has outside strings.
    private static func depth(_ text: String) -> Int {
        var depth = 0
        var quote: Character?
        var escaped = false
        for c in text {
            if let q = quote {
                if escaped { escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
            }
        }
        return depth
    }

    /// A line's code and its comment (from the #), if any.
    static func splitComment(_ line: String) -> (code: String, comment: String?) {
        var quote: Character?
        var escaped = false
        for i in line.indices {
            let c = line[i]
            if let q = quote {
                if escaped { escaped = false }
                else if c == "\\" && q == "\"" { escaped = true }
                else if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" {
                return (String(line[..<i]), String(line[i...]))
            }
        }
        return (line, nil)
    }
}
