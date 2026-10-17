import Foundation
import GitExtensionsCore

package enum DiffLinesMatcher {
    package struct Word: Equatable, Sendable {
        package let text: String
        package let start: Int
    }
    package struct Pair: Equatable, Sendable {
        package let removed: Int
        package let added: Int
    }

    package static func words(_ text: String) -> [Word] {
        var result: [Word] = [], current = ""
        var offset = 0, start = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                if current.isEmpty { start = offset }
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty { result.append(Word(text: current, start: start)); current = "" }
            offset += scalar.utf16.count
        }
        if !current.isEmpty { result.append(Word(text: current, start: start)) }
        return result
    }

    package static func subwords(_ text: String) -> [Word] {
        let source = text as NSString
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        var result: [Word] = []
        var start = 0, offset = 0
        var upper = CharacterSet.uppercaseLetters.contains(scalars[0])
        var previousAlphanumeric = false
        for (index, scalar) in scalars.enumerated() {
            let currentUpper = CharacterSet.uppercaseLetters.contains(scalar)
            if upper != currentUpper {
                upper = currentUpper
                if currentUpper {
                    if !(index == 1 && !CharacterSet.alphanumerics.contains(scalars[0])) && offset > start {
                        result.append(Word(text: source.substring(with: NSRange(location: start, length: offset - start)), start: start))
                    }
                    start = offset
                }
            }
            let alphanumeric = CharacterSet.alphanumerics.contains(scalar)
            if index > 0 && !alphanumeric {
                if start < offset && previousAlphanumeric {
                    result.append(Word(text: source.substring(with: NSRange(location: start, length: offset - start)), start: start))
                }
                start = offset + scalar.utf16.count
                upper = true
            }
            previousAlphanumeric = alphanumeric
            offset += scalar.utf16.count
        }
        if start < source.length && !(scalars.count == 1 && !CharacterSet.alphanumerics.contains(scalars[0])) {
            result.append(Word(text: source.substring(from: start), start: start))
        }
        return result
    }

    package static func bestMatch(_ removed: String, _ added: String) -> (word: String?, removed: Int, added: Int) {
        func match(_ r: [Word], _ a: [Word]) -> (String?, Int, Int)? {
            let names = Set(r.map(\.text))
            var seen = Set<String>(), best: Word?
            for word in a where names.contains(word.text) && seen.insert(word.text).inserted {
                if word.text.utf16.count > (best?.text.utf16.count ?? 0) { best = word }
            }
            guard let best, let old = r.first(where: { $0.text == best.text }) else { return nil }
            return (best.text, old.start, best.start)
        }
        let r = words(removed), a = words(added)
        return match(r, a) ?? match(r.flatMap { word in subwords(word.text).map { Word(text: $0.text, start: word.start + $0.start) } },
                                   a.flatMap { word in subwords(word.text).map { Word(text: $0.text, start: word.start + $0.start) } }) ?? (nil, 0, 0)
    }

    package static func combinations(_ n: Int, _ m: Int) -> [Pair] {
        guard n > 0, m > 0 else { return [] }
        var pairs: [Pair] = []
        for diagonal in 0..<n {
            for second in 0..<min(diagonal + 1, m) { pairs.append(Pair(removed: diagonal - second, added: second)) }
        }
        if m > 1 {
            for diagonal in 1..<m {
                for second in diagonal..<min(n + diagonal, m) { pairs.append(Pair(removed: n - 1 + diagonal - second, added: second)) }
            }
        }
        return pairs
    }

    package static func pairs(_ removed: [String], _ added: [String]) -> [Pair] {
        guard !removed.isEmpty, !added.isEmpty else { return [] }
        if removed.count * added.count == 1 || removed.count > 10_000 / added.count {
            return (0..<min(removed.count, added.count)).map { Pair(removed: $0, added: $0) }
        }
        struct Line {
            let trimmed: String
            let words: Set<String>
            let length: Int
            init(_ text: String) {
                trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                words = Set(DiffLinesMatcher.words(trimmed).map(\.text))
                length = words.reduce(0) { $0 + $1.utf16.count }
            }
        }
        let r = removed.map(Line.init), a = added.map(Line.init)
        var output: [Pair] = []
        func visit(_ rr: Range<Int>, _ aa: Range<Int>) {
            guard !rr.isEmpty, !aa.isEmpty else { return }
            var best = Pair(removed: rr.lowerBound, added: aa.lowerBound), longest = -1
            for i in rr {
                if let j = aa.first(where: { a[$0].trimmed == r[i].trimmed }), r[i].trimmed.utf16.count > longest {
                    longest = r[i].trimmed.utf16.count; best = Pair(removed: i, added: j)
                }
            }
            if longest < 0 {
                var score: Float = -1
                for pair in combinations(rr.count, aa.count) {
                    let i = rr.lowerBound + pair.removed, j = aa.lowerBound + pair.added
                    let next: Float = r[i].words.isEmpty || a[j].words.isEmpty ? -1
                        : Float(r[i].words.intersection(a[j].words).reduce(0) { $0 + $1.utf16.count }) / Float(max(r[i].length, a[j].length))
                    if score < next { score = next; best = Pair(removed: i, added: j); if score == 1 { break } }
                }
                if score <= 0.1 { best = Pair(removed: rr.lowerBound, added: aa.lowerBound) }
            }
            visit(rr.lowerBound..<best.removed, aa.lowerBound..<best.added)
            output.append(best)
            visit((best.removed + 1)..<rr.upperBound, (best.added + 1)..<aa.upperBound)
        }
        visit(r.indices, a.indices)
        return output
    }
}

package struct DiffInlineRanges: Equatable, Sendable {
    package var identical: [NSRange] = []
    package var anchors: [Int] = []
    package var changed: [NSRange] = []
}

package enum DiffInlineAnalysis {
    package static func ranges(removed: String, added: String) -> (removed: DiffInlineRanges, added: DiffInlineRanges) {
        func limited(_ text: String) -> String {
            var result = "", count = 0
            for scalar in text.unicodeScalars {
                guard count + scalar.utf16.count <= 2000 else { break }
                result.unicodeScalars.append(scalar); count += scalar.utf16.count
            }
            return result
        }
        let removed = limited(removed), added = limited(added)
        var old = DiffInlineRanges(), new = DiffInlineRanges()
        func emit(_ r: Int, _ a: Int, _ length: Int) {
            guard length > 0 else { return }
            old.identical.append(NSRange(location: r, length: length))
            new.identical.append(NSRange(location: a, length: length))
        }
        func visit(_ r: NSString, _ a: NSString, _ ro: Int, _ ao: Int) -> (Int, Int) {
            if r == a { return (r.length, 0) }
            var start = 0, end = 0
            let match = DiffLinesMatcher.bestMatch(r as String, a as String)
            if let word = match.word {
                var length = word.utf16.count, ri = match.removed, ai = match.added
                let rightR = ri + length, rightA = ai + length
                let right = visit(r.substring(from: rightR) as NSString, a.substring(from: rightA) as NSString, ro + rightR, ao + rightA)
                length += right.0; end = right.1
                let left = visit(r.substring(to: ri) as NSString, a.substring(to: ai) as NSString, ro, ao)
                start = left.0; length += left.1; ri -= left.1; ai -= left.1
                if ri == start && ai == start { start += length }
                else if ri + length + end == r.length && ai + length + end == a.length { end += length }
                else { emit(ro + ri, ao + ai, length) }
            } else {
                while start < min(r.length, a.length) && r.character(at: start) == a.character(at: start) { start += 1 }
                if start > 0, start < r.length, (0xDC00...0xDFFF).contains(r.character(at: start)) { start -= 1 }
                while end < r.length - start && end < a.length - start && r.character(at: r.length - end - 1) == a.character(at: a.length - end - 1) { end += 1 }
                if end > 0, end < r.length, (0xDC00...0xDFFF).contains(r.character(at: r.length - end)) { end -= 1 }
                let rd = r.length - start - end, ad = a.length - start - end
                if rd == 0 && ad > 0 { old.anchors.append(ro + start) }
                else if rd > 0 && ad == 0 { new.anchors.append(ao + start) }
            }
            return (start, end)
        }
        let result = visit(removed as NSString, added as NSString, 0, 0)
        emit(0, 0, result.0)
        emit(removed.utf16.count - result.1, added.utf16.count - result.1, result.1)
        func finish(_ value: inout DiffInlineRanges, _ length: Int) {
            value.identical.sort { $0.location < $1.location }
            var offset = 0
            for range in value.identical {
                if range.location > offset { value.changed.append(NSRange(location: offset, length: range.location - offset)) }
                offset = range.location + range.length
            }
            if offset < length { value.changed.append(NSRange(location: offset, length: length - offset)) }
        }
        finish(&old, removed.utf16.count); finish(&new, added.utf16.count)
        return (old, new)
    }

    package struct Block: Sendable {
        package let removed: [Int]
        package let added: [Int]
    }

    package static func blocks(_ lines: [DiffLine]) -> [Block] {
        var index = 0, output: [Block] = []
        func block(_ kind: DiffLine.Kind, found initial: Bool) -> [Int] {
            var found = initial, gap = 0, result: [Int] = []
            while index < lines.count {
                let line = lines[index]
                if line.kind != kind {
                    if !found { index += 1; continue }
                    if line.kind == .context && gap < 5 { gap += 1; index += 1; continue }
                    break
                }
                gap = 0
                if !line.isMovedLine { found = true; result.append(index) }
                index += 1
            }
            return result
        }
        while index < lines.count {
            let removed = block(.deletion, found: false)
            if removed.isEmpty { continue }
            let added = block(.addition, found: true)
            if added.isEmpty { continue }
            output.append(Block(removed: removed, added: added))
        }
        return output
    }

    package static func analyze(_ lines: [DiffLine]) -> [Int: DiffInlineRanges] {
        var output: [Int: DiffInlineRanges] = [:]
        for block in blocks(lines) {
            for pair in DiffLinesMatcher.pairs(block.removed.map { lines[$0].text }, block.added.map { lines[$0].text }) {
                let r = block.removed[pair.removed], a = block.added[pair.added]
                let ranges = ranges(removed: lines[r].text, added: lines[a].text)
                output[r] = ranges.removed; output[a] = ranges.added
            }
        }
        return output
    }
}
