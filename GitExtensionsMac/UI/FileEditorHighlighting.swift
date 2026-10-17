import AppKit

struct FileEditorHighlighting {
    enum Mode: Equatable {
        case plain
        case ordinary(FileViewerSyntaxMode)
        case commitMessage
        case rebaseTodo
    }
    enum Kind: Equatable {
        case syntax(FileViewerSyntaxTokenKind)
        case comment
        case summary
        case command(String)
        case commitID(String)
    }
    struct Token: Equatable {
        let range: NSRange
        let kind: Kind
    }
    struct Marker: Equatable {
        let range: NSRange
        let message: String
    }
    var tokens: [Token] = []
    var markers: [Marker] = []

    static func mode(for path: String) -> Mode {
        if path.hasSuffix("git-rebase-todo") { return .rebaseTodo }
        if path.hasSuffix("COMMIT_EDITMSG") { return .commitMessage }
        return FileViewerSyntaxRegistry.mode(for: path).map(Mode.ordinary) ?? .plain
    }

    static func build(text: String, path: String, commentSetting: String = "#") -> Self {
        let mode = mode(for: path)
        if case .ordinary(let syntax) = mode {
            return Self(tokens: FileViewerSyntaxLexer.tokens(text, mode: syntax).tokens.map { Token(range: $0.range, kind: .syntax($0.kind)) })
        }
        guard mode != .plain else { return Self() }
        let comment = commentSetting.utf16.count == 1 ? commentSetting : "#"
        let source = text as NSString
        var lines: [(text: String, range: NSRange, comment: Bool, empty: Bool)] = []
        var offset = 0
        while offset < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            let value = source.substring(with: NSRange(location: start, length: contentsEnd - start))
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append((value, NSRange(location: start, length: contentsEnd - start), trimmed.hasPrefix(comment), trimmed.isEmpty))
            offset = end
        }
        var result = Self()
        if mode == .rebaseTodo {
            let expression = try! NSRegularExpression(pattern: "^(p|pick|r|reword|e|edit|s|squash|f|fixup|x|exec|d|drop)(\\s+)([\\p{Nd}a-f]{4,})(\\s.*)$")
            let fixupExpression = try! NSRegularExpression(pattern: "^(f|fixup)\\s([\\-][Cc])(\\s*)([\\p{Nd}a-f]{4,})(\\s.*)$")
            let commands = ["p": "pick", "r": "reword", "e": "edit", "s": "squash", "f": "fixup", "x": "exec", "d": "drop"]
            for line in lines {
                if line.comment { result.tokens.append(Token(range: line.range, kind: .comment)); continue }
                let local = NSRange(location: 0, length: line.range.length)
                let withOption = fixupExpression.firstMatch(in: line.text, range: local)
                guard let match = withOption ?? expression.firstMatch(in: line.text, range: local) else { continue }
                let name = (line.text as NSString).substring(with: match.range(at: 1))
                let command = commands[name] ?? name
                let id = match.range(at: withOption == nil ? 3 : 4)
                result.tokens.append(Token(range: NSRange(location: line.range.location, length: id.location), kind: .command(command)))
                result.tokens.append(Token(range: NSRange(location: line.range.location + id.location, length: id.length), kind: .commitID(command)))
            }
            return result
        }
        var summary: Int?, description: Int?
        var dividingSpace = false
        for (index, line) in lines.enumerated() {
            if summary == nil {
                if !line.empty && !line.comment { summary = index }
            } else if !dividingSpace {
                if line.empty { dividingSpace = true }
                else if !line.comment { description = index; break }
            } else if description != nil, !line.empty && !line.comment {
                description = index
                break
            }
        }
        for (index, line) in lines.enumerated() {
            if line.comment { result.tokens.append(Token(range: line.range, kind: .comment)) }
            else if index == summary {
                result.tokens.append(Token(range: line.range, kind: .summary))
                if line.range.length > 50 {
                    result.markers.append(Marker(range: NSRange(location: line.range.location + 50, length: line.range.length - 50), message: "Summary line is too long."))
                }
            } else if index == description && !dividingSpace {
                result.markers.append(Marker(range: line.range, message: "There must be a blank line after the summary."))
            }
            if let description, index >= description, line.range.length > 80 {
                result.markers.append(Marker(range: NSRange(location: line.range.location + 80, length: line.range.length - 80), message: "Line is too long."))
            }
        }
        return result
    }

    @MainActor
    static func color(for command: String, dark: Bool) -> NSColor {
        switch command {
        case "pick": .textColor
        case "reword": dark ? NSColor(calibratedRed: 0.576, green: 0.439, blue: 0.859, alpha: 1) : .purple
        case "edit": dark ? .lightGray : .darkGray
        case "squash": dark ? NSColor(calibratedRed: 0.392, green: 0.584, blue: 0.929, alpha: 1) : NSColor(calibratedRed: 0, green: 0, blue: 0.545, alpha: 1)
        case "fixup": dark ? NSColor(calibratedRed: 1, green: 0.498, blue: 0.314, alpha: 1) : NSColor(calibratedRed: 0.941, green: 0.502, blue: 0.502, alpha: 1)
        case "exec": .secondaryLabelColor
        case "drop": dark ? NSColor(calibratedRed: 0.804, green: 0.361, blue: 0.361, alpha: 1) : .red
        default: .textColor
        }
    }
}
