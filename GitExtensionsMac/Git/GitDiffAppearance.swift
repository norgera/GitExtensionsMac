import Foundation
import GitExtensionsCore

package enum AnsiEscapeParser {
    package struct Result: Equatable {
        package var text: String
        package var styles: [DiffTextStyle]
    }

    private static let defaultColorID = -2
    private static let escape = try! NSRegularExpression(pattern: "\u{1b}\\[([0-9;: ]*)m")

    package static func parse(_ text: String, themeColors: Bool = false) -> Result {
        let source = text as NSString
        let output = NSMutableString()
        var styles: [DiffTextStyle] = []
        var currentColorID = defaultColorID
        var active: (start: Int, foreground: DiffTextColor?, background: DiffTextColor?)?
        var previous = 0

        func endCurrent() {
            guard let current = active else { return }
            active = nil
            let length = output.length - current.start
            guard length > 0 else { return }
            if length == 1, output.character(at: output.length - 1) == 13 { return }
            if var last = styles.last, last.foreground == current.foreground, last.background == current.background {
                let gapStart = last.location + last.length
                let gap = current.start - gapStart
                let gapText = gap > 0 ? output.substring(with: NSRange(location: gapStart, length: gap)) : ""
                if gap == 0 || gapText == "\n" || gapText == "\r\n" {
                    last.length = output.length - last.location
                    styles[styles.count - 1] = last
                    return
                }
            }
            styles.append(DiffTextStyle(location: current.start, length: length, foreground: current.foreground, background: current.background))
        }

        for match in escape.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output.append(source.substring(with: NSRange(location: previous, length: match.range.location - previous)))
            previous = NSMaxRange(match.range)
            let codes = source.substring(with: match.range(at: 1))
                .split(whereSeparator: { $0 == ";" || $0 == ":" })
                .map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            if let colors = colors(codes, currentColorID: &currentColorID, themeColors: themeColors) {
                endCurrent()
                active = (output.length, colors.foreground, colors.background)
            } else {
                endCurrent()
            }
        }
        output.append(source.substring(from: previous))
        endCurrent()
        return Result(text: output as String, styles: styles)
    }

    private static func colors(_ supplied: [Int], currentColorID: inout Int, themeColors: Bool) -> (foreground: DiffTextColor?, background: DiffTextColor?)? {
        let codes = supplied.isEmpty ? [0] : supplied
        var foreground: DiffTextColor?
        var background: DiffTextColor?
        var currentForeground = -1
        var currentBackground = -1
        var reverse = false
        var bold = false
        var dim = false
        var isChange = false
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0:
                reverse = false
                foreground = nil
                background = nil
                currentColorID = defaultColorID
                currentForeground = -1
                currentBackground = -1
                bold = false
                dim = false
            case 1, 4, 5, 6, 9:
                bold = true
                isChange = true
            case 2, 3, 8:
                dim = true
                isChange = true
            case 7:
                reverse = true
            case 22:
                bold = false
                dim = false
            case 39:
                foreground = nil
                currentColorID = defaultColorID
                currentForeground = defaultColorID
            case 49:
                background = nil
                currentBackground = -1
                isChange = true
            case 30...37:
                currentForeground = code - 30
            case 90...97:
                currentForeground = code - 90 + 8
            case 40...47:
                currentBackground = code - 40
            case 100...107:
                currentBackground = code - 100 + 8
            case 38, 48:
                guard index < codes.count - 2 else { break }
                let isForeground = code == 38
                index += 1
                if codes[index] == 5 {
                    index += 1
                    if isForeground { currentForeground = codes[index] } else { currentBackground = codes[index] }
                } else if codes[index] == 2, index < codes.count - 3 {
                    let color = DiffTextColor.rgb(codes[index + 1], codes[index + 2], codes[index + 3])
                    index += 3
                    currentColorID = defaultColorID
                    if isForeground {
                        currentForeground = -1
                        foreground = color
                    } else {
                        currentBackground = -1
                        background = color
                    }
                }
            default:
                break
            }
            index += 1
        }

        if (0...15).contains(currentForeground) {
            currentColorID = currentForeground & 7
        }
        if themeColors, !reverse, !dim, currentBackground < 0, background == nil, foreground == nil,
           [1, 2, 9, 10].contains(currentForeground) {
            var backBold = bold
            var backDim = false
            if currentForeground > 7 {
                currentForeground -= 8
            } else if bold {
                backBold = false
            } else {
                backDim = true
            }
            background = color(currentForeground, bold: backBold, dim: backDim)
            currentForeground = -1
        }
        if isChange, foreground == nil, background == nil, currentForeground < 0, currentBackground < 0 {
            currentForeground = currentColorID
        }
        if reverse {
            swap(&background, &foreground)
            swap(&currentBackground, &currentForeground)
        }
        if currentForeground >= 0 || currentForeground == defaultColorID {
            foreground = color(currentForeground, bold: bold, dim: dim)
        }
        if currentBackground >= 0 || currentBackground == defaultColorID {
            background = color(currentBackground, bold: bold, dim: dim)
        }
        return foreground == nil && background == nil ? nil : (foreground, background)
    }

    private static func color(_ id: Int, bold: Bool, dim: Bool) -> DiffTextColor {
        if id == defaultColorID { return .text(dim: dim) }
        return .palette(bold && (0...7).contains(id) ? id + 8 : id, dim: dim)
    }
}

package enum GitDiffAppearance {
    package static let difftasticCommandKey = "difftool.difftastic.cmd"
    package static let wordDiffArguments = ["--word-diff=color", "--color=always"]
    package static let colorConfigurationPattern = "^(diff\\.(colormovedws|wordregex|colormoved)|color\\.diff\\.((old|new)(dimmed)?|(old|new)moved(alternative)?(dimmed)?))$"

    package static func colorConfiguration(configured: Set<String>, reverse: Bool = true) -> [String] {
        let values: [(String, String)] = [
            ("diff.colormovedws", "no"),
            ("diff.wordregex", "[a-z0-9_]+|."),
            ("diff.colormoved", "dimmed-zebra"),
            ("color.diff.old", "red reverse"),
            ("color.diff.new", "green reverse"),
            ("color.diff.olddimmed", "red dim reverse"),
            ("color.diff.newdimmed", "green dim reverse"),
            ("color.diff.oldmoved", "black brightmagenta"),
            ("color.diff.newmoved", "black brightblue"),
            ("color.diff.oldmovedalternative", "black brightcyan"),
            ("color.diff.newmovedalternative", "black brightyellow"),
            ("color.diff.oldmoveddimmed", "magenta dim reverse"),
            ("color.diff.newmoveddimmed", "blue dim reverse"),
            ("color.diff.oldmovedalternativedimmed", "cyan dim reverse"),
            ("color.diff.newmovedalternativedimmed", "yellow dim reverse")
        ]
        return values.filter { !configured.contains($0.0) && (reverse || (!$0.1.hasPrefix("black bright") && !["color.diff.olddimmed", "color.diff.newdimmed"].contains($0.0))) }
            .flatMap { ["-c", "\($0.0)=\(reverse ? $0.1 : $0.1.replacingOccurrences(of: " reverse", with: ""))"] }
    }

    package static func configuredKeys(fromGetRegexp output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.split(separator: " ", maxSplits: 1).first.map { $0.lowercased() }
        })
    }

    package static func wordDiffCommand(_ patchArguments: [String], configured: Set<String>, reverse: Bool = true) -> [String] {
        var arguments = patchArguments.filter { $0 != "--no-color" }
        let insertion = min(1, arguments.count)
        arguments.insert(contentsOf: wordDiffArguments, at: insertion)
        return colorConfiguration(configured: configured, reverse: reverse) + arguments
    }

    package static func parseColoredPatch(_ output: Data, file: ChangedFile) -> FileDiff? {
        let parsed = AnsiEscapeParser.parse(String(decoding: output, as: UTF8.self))
        guard let diff = GitOutputParser.parseUnifiedDiff(Data(parsed.text.utf8), files: [file])[file.id] else { return nil }
        var start = 0
        let lines = diff.lines.map { line -> DiffLine in
            let prefix = [.context, .addition, .deletion].contains(line.kind) && !line.text.hasPrefix("\\ No newline") ? 1 : 0
            let length = (line.text as NSString).length
            let styles = clip(parsed.styles, start: start + prefix, length: length)
            start += length + prefix + 1
            return DiffLine(id: line.id, oldLineNumber: line.oldLineNumber, newLineNumber: line.newLineNumber, kind: line.kind, text: line.text, styles: styles)
        }
        return FileDiff(id: diff.id, fileID: file.id, lines: lines)
    }

    package static func difftasticArguments(revisions: [String], paths: [String], noIndex: Bool, options: FileDiffOptions) -> [String] {
        ["--no-pager", "difftool", "--find-renames", "--find-copies", "-y", "--tool=difftastic"]
            + (options.treatsAllFilesAsText ? ["--text"] : [])
            + (noIndex ? ["--no-index"] : [])
            + revisions + ["--"] + paths
    }

    package static func difftasticEnvironment(_ options: FileDiffOptions) -> [String: String] {
        [
            "DFT_COLOR": "always",
            "DFT_BACKGROUND": "light",
            "DFT_SYNTAX_HIGHLIGHT": options.difftasticSyntaxHighlighting ? "on" : "off",
            "DFT_CONTEXT": String(options.showsEntireFile ? 9000 : options.contextLines),
            "DFT_STRIP_CR": options.whitespace == .none ? "off" : "on",
            "DFT_WIDTH": String(options.difftasticWidth)
        ]
    }

    package static func difftasticWidth(viewerWidth: CGFloat) -> Int {
        max(88, min(200, Int(viewerWidth) / 7)) / 2 * 2
    }

    package static func parseWordDiff(_ output: Data, file: ChangedFile) -> FileDiff {
        let parsed = AnsiEscapeParser.parse(String(decoding: output, as: UTF8.self))
        let text = parsed.text as NSString
        var lines: [DiffLine] = []
        var left = 0
        var right = 0
        var headerFound = false
        var lineStart = 0
        var rawLines = parsed.text.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }
        for (index, rawLine) in rawLines.enumerated() {
            let fullLength = (rawLine as NSString).length
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let length = (line as NSString).length
            let intersecting = parsed.styles.filter { $0.location < lineStart + length && $0.location + $0.length - 1 >= lineStart }
            let styles = clip(intersecting, start: lineStart, length: length)
            let id = String(index)
            if line.hasPrefix("@@") {
                let numbers = hunkStarts(line)
                left = numbers.left
                right = numbers.right
                headerFound = true
                lines.append(DiffLine(id: id, oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: line, styles: styles))
            } else if !headerFound {
                lines.append(DiffLine(id: id, oldLineNumber: nil, newLineNumber: nil, kind: .header, text: line, styles: styles))
            } else if isGitWordMatch(red: true, line: line, start: lineStart, length: length, markers: intersecting) {
                lines.append(DiffLine(id: id, oldLineNumber: left, newLineNumber: nil, kind: .deletion, text: line, styles: styles))
                left += 1
            } else if isGitWordMatch(red: false, line: line, start: lineStart, length: length, markers: intersecting) {
                lines.append(DiffLine(id: id, oldLineNumber: nil, newLineNumber: right, kind: .addition, text: line, styles: styles))
                right += 1
            } else {
                lines.append(DiffLine(id: id, oldLineNumber: left, newLineNumber: right, kind: .context, text: line,
                                      styles: styles, isMixedChange: !intersecting.isEmpty))
                left += 1
                right += 1
            }
            lineStart += min(fullLength + 1, text.length - lineStart)
        }
        return FileDiff(id: file.id, fileID: file.id, lines: lines, appearance: .gitWordDiff)
    }

    private static func isGitWordMatch(red: Bool, line: String, start: Int, length: Int, markers: [DiffTextStyle]) -> Bool {
        guard markers.count == 1, let marker = markers.first else { return false }
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let firstNonWhitespace = (line as NSString).length - (String(trimmed) as NSString).length
        let end = marker.location + marker.length - 1
        return (marker.location <= start || (firstNonWhitespace > 0 && marker.location <= start + firstNonWhitespace))
            && end >= start + length - 3
            && (marker.background == .palette(red ? 1 : 2, dim: false) || marker.foreground == .palette(red ? 1 : 2, dim: false))
    }

    private static func hunkStarts(_ line: String) -> (left: Int, right: Int) {
        let pattern = try! NSRegularExpression(pattern: "-(\\d+),*(\\d*)\\s\\+(\\d+),*(\\d*)")
        let source = line as NSString
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else { return (0, 0) }
        return (Int(source.substring(with: match.range(at: 1))) ?? 0, Int(source.substring(with: match.range(at: 3))) ?? 0)
    }

    private static func clip(_ styles: [DiffTextStyle], start: Int, length: Int) -> [DiffTextStyle] {
        styles.compactMap { style in
            let lower = max(style.location, start)
            let upper = min(style.location + style.length, start + length)
            guard upper > lower else { return nil }
            return DiffTextStyle(location: lower - start, length: upper - lower, foreground: style.foreground, background: style.background)
        }
    }

    package static func parseDifftastic(_ output: Data, file: ChangedFile, width: Int, reverse: Bool = true) -> FileDiff {
        let column = width > 0 ? width : 80
        let halfColumn = column / 2
        let lineNumber = try! NSRegularExpression(pattern: "^(\\s*(?<matchStart>(?<lineNo>\\d+)|(\\.+)) )")
        var lines: [DiffLine] = []
        var nextIsHeader = true
        var rightColumnStart = 0

        func append(_ text: String, _ styles: [DiffTextStyle], kind: DiffLine.Kind, left: Int?, right: Int?, mixed: Bool = false) {
            lines.append(DiffLine(id: String(lines.count), oldLineNumber: left, newLineNumber: right, kind: kind, text: text,
                                  styles: styles.filter { $0.length > 0 }, isMixedChange: mixed))
        }

        for rawLine in String(decoding: output, as: UTF8.self).components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                nextIsHeader = true
                continue
            }
            let parsed = AnsiEscapeParser.parse(rawLine, themeColors: reverse)
            var text = parsed.text
            var styles = parsed.styles
            var left: Int?
            var right: Int?
            if nextIsHeader {
                nextIsHeader = false
                append(text, styles, kind: .header, left: nil, right: nil)
                continue
            }
            var kind = DifftasticLineType.context
            let nsText = text as NSString
            guard let leftMatch = lineNumber.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else {
                append(text, styles, kind: .context, left: nil, right: nil)
                continue
            }
            var leftLength: Int
            if leftMatch.range(withName: "matchStart").location >= halfColumn {
                leftLength = 0
                if rightColumnStart > 0 { leftLength = halfColumn - rightColumnStart }
            } else {
                leftLength = leftMatch.range.length
                let numberRange = leftMatch.range(withName: "lineNo")
                if numberRange.location != NSNotFound { left = Int(nsText.substring(with: numberRange)) }
                if let first = styles.first, first.location < leftLength, let change = change(first) {
                    if change == .removed {
                        kind = .minusLeft
                    } else {
                        kind = .plusRight
                        right = left
                        left = nil
                    }
                }
            }
            if leftLength > 0 {
                text = (text as NSString).replacingCharacters(in: NSRange(location: 0, length: min(leftLength, (text as NSString).length)), with: "")
                styles = styles.map { removing($0, offset: 0, length: leftLength) }
            }
            var rightStartOffset = halfColumn - leftLength
            var rightMatch: NSTextCheckingResult?
            let current = text as NSString
            if current.length > rightStartOffset, rightStartOffset >= 0,
               let match = lineNumber.firstMatch(in: current.substring(from: rightStartOffset), range: NSRange(location: 0, length: current.length - rightStartOffset)) {
                rightMatch = match
                if rightColumnStart == 0 { rightColumnStart = rightStartOffset }
            } else {
                rightStartOffset = 0
                rightMatch = lineNumber.firstMatch(in: text, range: NSRange(location: 0, length: current.length))
            }
            guard let rightMatch else {
                append(text, styles, kind: kind.lineKind, left: left, right: right, mixed: kind == .minusPlus)
                continue
            }
            let searched = rightStartOffset > 0 ? current.substring(from: rightStartOffset) as NSString : current
            let rightNumberRange = rightMatch.range(withName: "lineNo")
            if rightNumberRange.location != NSNotFound { right = Int(searched.substring(with: rightNumberRange)) }
            let rightLength = rightMatch.range.length
            text = current.replacingCharacters(in: NSRange(location: rightStartOffset, length: rightLength), with: "")
            var columnGap = 0
            if rightStartOffset > 0 {
                if rightColumnStart == 0 { rightColumnStart = rightStartOffset }
                columnGap = rightColumnStart - rightStartOffset
                if columnGap > 0 {
                    text = (text as NSString).replacingCharacters(in: NSRange(location: rightStartOffset, length: 0), with: String(repeating: " ", count: columnGap))
                }
            }
            var first = true
            styles = styles.map { style in
                guard style.location + style.length - 1 >= rightStartOffset else { return style }
                if first {
                    first = false
                    if change(style) != nil {
                        kind = kind == .context ? .plusRight : .minusPlus
                    }
                }
                var updated = removing(style, offset: rightStartOffset, length: rightLength)
                if updated.location >= rightStartOffset { updated.location += columnGap }
                return updated
            }
            append(text, styles, kind: kind.lineKind, left: left, right: right, mixed: kind == .minusPlus)
        }
        return FileDiff(id: file.id, fileID: file.id, lines: lines, appearance: .difftastic)
    }

    private enum DifftasticLineType { case context, minusLeft, plusRight, minusPlus
        var lineKind: DiffLine.Kind {
            switch self {
            case .context, .minusPlus: .context
            case .minusLeft: .deletion
            case .plusRight: .addition
            }
        }
    }

    private enum Change { case removed, added }

    private static func change(_ style: DiffTextStyle) -> Change? {
        guard case .palette(let id, _)? = style.background else { return nil }
        switch id {
        case 1, 9: return .removed
        case 2, 10: return .added
        default: return nil
        }
    }

    private static func removing(_ style: DiffTextStyle, offset: Int, length: Int) -> DiffTextStyle {
        var result = style
        if result.location + result.length <= offset { return result }
        if result.location >= offset + length {
            result.location -= length
            return result
        }
        if result.location <= offset && offset + length <= result.location + result.length {
            result.length -= length
            return result
        }
        if result.location > offset {
            result.length -= result.location - offset
            result.location = offset
            return result
        }
        result.length -= result.location + result.length - offset
        return result
    }
}

package enum GitResetLinePatchBuilder {
    package static func patch(from diff: FileDiff, selecting lineIDs: Set<String>) -> Data? {
        let selected = Set(diff.lines.filter { lineIDs.contains($0.id) && ($0.kind == .addition || $0.kind == .deletion) }.map(\.id))
        guard !selected.isEmpty, let firstHunk = diff.lines.firstIndex(where: { $0.kind == .hunk }) else { return nil }
        let hunkStarts = diff.lines.indices.filter { diff.lines[$0].kind == .hunk }
        var output = diff.lines[..<firstHunk].map(\.text)
        if output.contains("--- /dev/null"),
           let newPath = output.first(where: { $0.hasPrefix("+++ ") }).map({ String($0.dropFirst(4)) }), newPath != "/dev/null" {
            let oldPath = newPath.hasPrefix("\"b/") ? "\"a/" + newPath.dropFirst(3) : newPath.replacingOccurrences(of: "b/", with: "a/", options: .anchored)
            output = output.compactMap { line in
                if line.hasPrefix("new file mode ") { return nil }
                return line == "--- /dev/null" ? "--- \(oldPath)" : line
            }
        }
        var emitted = false
        for (offset, start) in hunkStarts.enumerated() {
            let end = offset + 1 < hunkStarts.count ? hunkStarts[offset + 1] : diff.lines.endIndex
            let body = Array(diff.lines[(start + 1)..<end])
            guard body.contains(where: { selected.contains($0.id) }), let newStart = newStart(diff.lines[start].text) else { continue }
            var rewritten: [String] = []
            var oldCount = 0
            var newCount = 0
            var previous: (line: DiffLine, emitted: Bool)?
            for line in body {
                switch line.kind {
                case .context:
                    rewritten.append(" " + line.text)
                    oldCount += 1
                    newCount += 1
                    previous = (line, true)
                case .addition:
                    if selected.contains(line.id) {
                        rewritten.append("-" + line.text)
                        oldCount += 1
                    } else {
                        rewritten.append(" " + line.text)
                        oldCount += 1
                        newCount += 1
                    }
                    previous = (line, true)
                case .deletion:
                    if selected.contains(line.id) {
                        rewritten.append("+" + line.text)
                        newCount += 1
                    }
                    previous = (line, selected.contains(line.id))
                case .header:
                    if line.text.hasPrefix("\\ No newline at end of file"), previous?.emitted == true {
                        rewritten.append(line.text)
                    }
                case .hunk:
                    break
                }
            }
            guard rewritten.contains(where: { $0.hasPrefix("+") || $0.hasPrefix("-") }) else { continue }
            output.append("@@ -\(newStart),\(oldCount) +\(newStart),\(newCount) @@")
            output.append(contentsOf: rewritten)
            emitted = true
        }
        guard emitted else { return nil }
        var text = output.joined(separator: "\n")
        if !text.hasSuffix("\n") { text.append("\n") }
        return Data(text.utf8)
    }

    private static func newStart(_ header: String) -> Int? {
        guard let field = header.split(separator: " ").first(where: { $0.hasPrefix("+") }) else { return nil }
        return Int(field.dropFirst().split(separator: ",", maxSplits: 1)[0])
    }
}
