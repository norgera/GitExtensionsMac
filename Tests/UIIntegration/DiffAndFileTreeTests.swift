import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Diff and file tree")
    enum DiffAndFileTreeTests {

        static func item(_ path: String, old: String? = nil, type: FileChangeType = .modified) -> ChangedFile {
            ChangedFile(id: path, path: path, oldPath: old, changeType: type, additions: 0, deletions: 0)
        }

        static func fixture(_ name: String) throws -> String {
            try String(contentsOf: TestResources.fixtures.appendingPathComponent("DiffAndFileTree/" + name), encoding: .utf8)
        }

        @Test("Trees") static func trees() throws {
            let paths = [
                "root_file", ".hidden_root_file", "ext/submodule/", "ext/subfolder/filees", "ext/s/", "ext/file", "ext2/file",
                "1/file1", "1/submodule_sorted_as_file/", "1/subfolder/file1s", "1/2/file12", "1/3/file13", "1/3/4/file134",
                "5/file1", "5/6/file56b", "5/6/file56a", "5/7/file57b", "5/7/file57a", "5/7/8/file578",
            ]
            func serialized(_ nodes: [FileStatusPathNode]) -> [String: Any] {
                func node(_ n: FileStatusPathNode) -> [String: Any] {
                    [
                        "Text": n.title, "Tag": (n.file == nil ? "RelativePath: " : "FileStatusItem: ") + n.path,
                        "Nodes": n.children.map(node),
                    ]
                }
                return ["Text": "", "Tag": "RelativePath: ", "Nodes": nodes.map(node)]
            }
            func snapshot(_ name: String, _ files: [ChangedFile], flat: Bool, dense: Bool) throws {
                let actual = serialized(FileStatusPaths.build(files, flat: flat, dense: dense)) as NSDictionary
                let expected = try JSONSerialization.jsonObject(with: Data(fixture("file-tree-" + name + ".json").utf8)) as! NSDictionary
                #expect(actual == expected, "tree snapshot \(name): \(actual)")
            }
            let files = paths.map { item($0, old: $0 == "5/7/8/file578" ? "oldfolder/of/renamed/file/" + $0 : nil) }
            for flat in [false, true] {
                for dense in [false, true] {
                    try snapshot("folders-first-\(flat ? "flat" : "nested")-\(dense ? "merged" : "separate")", files, flat: flat, dense: dense)
                }
                try snapshot("root-file-\(flat ? "flat" : "nested")", [item("root_file")], flat: flat, dense: true)
            }
            try snapshot("no-split-folders", ["core/c.1", "core/c.2", "core.dot/cd.3", "core/api/c_a.0"].map { item($0) }, flat: false, dense: false)
            for dense in [false, true] {
                try snapshot(
                    "single-file-subfolders-\(dense ? "merged" : "separate")", ["1/2/file12", "1/3/file13", "1/4/file14"].map { item($0) }, flat: false,
                    dense: dense)
            }
            let common = [
                ("", "", ""), ("a", "a", "a"), ("a", "b", ""), ("a", "ab", ""), ("a", "a/b", "a"),
                ("a", "a/b/c", "a"), ("a/b", "a/bc", "a"), ("a/b", "a/b", "a/b"), ("a/b", "a/b/c", "a/b"),
                ("a/b/cc", "a/b/ccd", "a/b"), ("a/b/cc", "a/b/cc/de", "a/b/cc"),
            ]
            for (a, b, expected) in common {
                #expect(FileStatusPaths.commonPath(a, b) == expected && FileStatusPaths.commonPath(b, a) == expected, "common path")
            }
            #expect(FileStatusPaths.precedes("dir/sub/file", "dir.ext/file") && !FileStatusPaths.precedes("dir.ext/file", "dir/sub/file"), "component sorting")
            let international = ["z/file", "Z/file", "é/file", "a/file", "ä/file", "root", ".hidden", "日本/子/file"]
            let forward = FileStatusPaths.build(international.map { item($0) }, flat: true, dense: false).map(\.path)
            let backward = FileStatusPaths.build(international.reversed().map { item($0) }, flat: true, dense: false).map(\.path)
            #expect(forward == backward && Array(forward.suffix(2)) == [".hidden", "root"], "deterministic invariant non-ASCII and case ordering")
            let compressed = FileStatusPaths.build([item("a/b/c/file")], flat: false, dense: false)
            #expect(compressed[0].title == "a/b/c" && compressed[0].children[0].title == "file", "folder-chain compression independent of dense")
            #expect(!FileStatusListPreferences().usesDenseTree, "dense default false")
            let explicit = try JSONDecoder().decode(FileStatusListPreferences.self, from: Data("{\"usesDenseTree\":true}".utf8))
            #expect(explicit.usesDenseTree, "existing dense preference preserved")
        }

        @Test("Matcher") static func matcher() {
            let words: [(String, [String], [Int])] = [
                ("", [], []), ("a", ["a"], [0]), ("a-", ["a"], [0]), ("-a", ["a"], [1]),
                ("a bc", ["a", "bc"], [0, 2]), ("-a bc", ["a", "bc"], [1, 3]), ("a bc-", ["a", "bc"], [0, 2]),
                ("---abc---123---def_7---", ["abc", "123", "def_7"], [3, 9, 15]),
            ]
            let subwords: [(String, [String], [Int])] = [
                ("", [], []), ("_", [], []), ("a", ["a"], [0]), ("A", ["A"], [0]),
                ("camelCase", ["camel", "Case"], [0, 5]), ("DelphiCase", ["Delphi", "Case"], [0, 6]),
                ("_precedingUnderScore", ["_preceding", "Under", "Score"], [0, 10, 15]), ("python_style", ["python", "style"], [0, 7]),
                ("multiple__under___scores_", ["multiple", "under", "scores"], [0, 10, 18]),
                ("CAPITALSwithsuffixNext_Upper_lower", ["CAPITALSwithsuffix", "Next", "Upper", "lower"], [0, 18, 23, 29]),
                ("    sum += x;", ["sum", "x"], [4, 11]),
            ]
            for (vectors, get) in [(words, DiffLinesMatcher.words), (subwords, DiffLinesMatcher.subwords)] {
                for (text, expected, offsets) in vectors {
                    let result = get(text)
                    #expect(result.map(\.text) == expected && result.map(\.start) == offsets, "words/subwords \(text): \(result)")
                }
            }
            for n in 1...4 {
                for m in 1...4 {
                    let combinations = DiffLinesMatcher.combinations(n, m)
                    #expect(combinations.count == n * m && Set(combinations.map { "\($0.removed):\($0.added)" }).count == n * m, "all 16 combination matrices")
                }
            }
            func pairs(_ r: [String], _ a: [String]) -> [String] { DiffLinesMatcher.pairs(r, a).map { "\($0.removed):\($0.added)" } }
            #expect(pairs(["r0", " trimmed line\t", "r2"], ["a0", "a1", "a2", "trimmed line", "a4"]) == ["0:0", "1:3", "2:4"], "trimmed matcher vector")
            #expect(
                pairs(
                    ["line 0 had some words", "line 1 had some more common words", " trimmed line\t", "r2"],
                    ["some words", "line 1 has some words", "line 2 has some common words", "trimmed line", "a4"]) == ["0:1", "1:2", "2:3", "3:4"],
                "similarity matcher vector")
            var largeAdded = Array(repeating: "other line", count: 1001)
            for index in 0..<10 { largeAdded[index + 10] = "line\(index)" }
            #expect(pairs((0..<10).map { "line\($0)" }, largeAdded) == (0..<10).map { "\($0):\($0)" }, "upstream >10000 fallback")
            #expect(pairs([], [""]).isEmpty && pairs([""], [""]) == ["0:0"], "empty line pairing")
        }

        @Test("Inline") static func inline() throws {
            let before = "identical_part_before_"
            let after = "_identical_part_after"
            let r = before + "RemovedX" + after
            let a = before + "AddedY" + after
            let ranges = DiffInlineAnalysis.ranges(removed: r, added: a)
            #expect(
                ranges.removed.identical == [NSRange(location: 0, length: before.count), NSRange(location: before.count + 8, length: after.count)],
                "upstream identical old spans")
            #expect(
                ranges.added.identical == [NSRange(location: 0, length: before.count), NSRange(location: before.count + 6, length: after.count)],
                "upstream identical new spans")
            let b = " identical_part_before "
            let e = " identical_part_after "
            let anchors = DiffInlineAnalysis.ranges(removed: "deletion" + b + "RemovedX" + e, added: b + "AddedY" + e + "insertion")
            #expect(anchors.removed.anchors == [8 + b.count + 8 + e.count] && anchors.added.anchors == [0], "upstream anchors")
            #expect(
                anchors.removed.identical == [NSRange(location: 8, length: b.count), NSRange(location: 8 + b.count + 8, length: e.count)],
                "upstream internal identical spans")
            let multiple = DiffInlineAnalysis.ranges(removed: "one OLD two OLD three", added: "one NEW two NEW three")
            #expect(multiple.removed.changed.count == 2 && multiple.added.changed.count == 2, "multiple changed spans")
            let unicode = DiffInlineAnalysis.ranges(removed: "🦊 café OLD 日本", added: "🐱 café NEW 日本")
            #expect(unicode.removed.changed.first == NSRange(location: 0, length: 2), "Unicode scalar boundary")
            #expect(DiffInlineAnalysis.ranges(removed: "", added: "new").removed.anchors == [0], "empty side anchor")
            let file = item("gaps")
            let parsed = GitDiffAppearance.parseColoredPatch(Data(try fixture("gaps.diff").utf8), file: file)!
            var offset = 0
            let locations = parsed.lines.map { line -> NSRange in
                defer { offset += line.patchText.utf16.count + 1 }
                return NSRange(location: offset, length: line.patchText.utf16.count)
            }
            let blocks = DiffInlineAnalysis.blocks(parsed.lines)
            let actual = blocks.flatMap { block in (block.removed + block.added).map { locations[$0] } }
            let expected = [(388, 106), (707, 104), (812, 1), (967, 106), (1074, 1), (1147, 1), (1149, 104), (1580, 10), (1591, 1), (1621, 25), (1647, 1)].map {
                NSRange(location: $0, length: $1)
            }
            #expect(blocks.count == 3 && actual == expected, "upstream MarkInlineGap snapshot \(actual)")
            let moved = [
                DiffLine(id: "m", oldLineNumber: 1, newLineNumber: nil, kind: .deletion, text: "moved", isMovedLine: true),
                DiffLine(id: "d", oldLineNumber: 2, newLineNumber: nil, kind: .deletion, text: "hello old"),
                DiffLine(id: "c", oldLineNumber: 3, newLineNumber: 1, kind: .context, text: "context"),
                DiffLine(id: "a", oldLineNumber: nil, newLineNumber: 2, kind: .addition, text: "hello new"),
            ]
            #expect(DiffInlineAnalysis.analyze(moved)[0] == nil && DiffInlineAnalysis.analyze(moved)[1] != nil, "moved line and context window")
            let whitespace = DiffInlineAnalysis.ranges(removed: "\t x  ", added: " x ")
            #expect(!whitespace.removed.changed.isEmpty, "tabs and whitespace changes")
        }

        @Test("Combined") static func combined() throws {
            let file = item("combined")
            let parsed = GitOutputParser.parseUnifiedDiff(Data(try fixture("SampleCombined.diff").utf8), files: [file])[file.id]!
            let vector = try JSONSerialization.jsonObject(with: Data(fixture("SampleCombined.expected.json").utf8)) as! [[String: Any]]
            #expect(vector.count == parsed.lines.count, "full combined vector length")
            for (line, expected) in zip(parsed.lines, vector) {
                #expect(
                    String(describing: line.kind) == expected["kind"] as? String && line.newLineNumber == expected["right"] as? Int
                        && line.oldLineNumber == nil, "full combined kind/number vector \(line.id)")
            }
            let expected: [(Int, Int?, DiffLine.Kind)] = [
                (6, 70, .context), (9, 73, .addition), (19, 83, .addition), (34, 100, .context), (37, nil, .deletion), (38, 103, .addition),
            ]
            for (number, right, kind) in expected {
                let line = parsed.lines[number - 1]
                #expect(line.oldLineNumber == nil && line.newLineNumber == right && line.kind == kind, "SampleCombined upstream vector \(number): \(line)")
            }
            let patch = "diff --cc f\n@@@ -1,3 -2,4 +8,5 @@@\n+ a\n +b\n- c\n -d\n++e\n--f\n  g\n+-h\n"
            let lines = GitOutputParser.parseUnifiedDiff(Data(patch.utf8), files: [file])[file.id]!.lines
            #expect(
                lines[1].hunkRanges?.parents == [.init(start: 1, count: 3), .init(start: 2, count: 4)]
                    && lines[1].hunkRanges?.result == .init(start: 8, count: 5), "all combined hunk ranges typed")
            #expect(lines[2...9].map(\.newLineNumber) == [8, 9, nil, nil, 10, nil, 11, 12], "two-column result progression")
            #expect(lines[2...9].map(\.kind) == [.addition, .addition, .deletion, .deletion, .addition, .deletion, .context, .context], "two-column kinds")
            #expect(
                lines[2...9].map(\.patchText).joined(separator: "\n") == patch.components(separatedBy: "\n")[2...9].joined(separator: "\n"),
                "combined copy preserves both prefix columns")
            #expect(GitResetLinePatchBuilder.patch(from: parsed, selecting: Set(parsed.lines.map(\.id))) == nil, "combined line reset ineligible")
            let normal = GitOutputParser.parseUnifiedDiff(Data("@@ -3,2 +7,2 @@\n old\n-removed\n+added\n".utf8), files: [file])[file.id]!.lines
            #expect(
                normal[1].oldLineNumber == 3 && normal[1].newLineNumber == 7 && normal[2].oldLineNumber == 4 && normal[3].newLineNumber == 8,
                "unified progression unchanged")
            let malformed = GitOutputParser.parseUnifiedDiff(Data("@@@ nonsense @@@\n+ x\n".utf8), files: [file])[file.id]!
            #expect(malformed.lines.allSatisfy { $0.newLineNumber == nil }, "malformed combined safe")
        }

        @Test("Copy") static func copy() {
            let patch = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n common\r\n-old\r\n+new\r\n"
            let start = (patch as NSString).range(of: " common").location
            let selection = NSRange(location: start, length: (patch as NSString).length - start)
            #expect(
                FileViewerCopy.payload(.patch, text: patch, selection: selection) == " common\r\n-old\r\n+new\r\n", "copy patch selected and unchanged endings")
            #expect(FileViewerCopy.payload(.patch, text: patch) == patch, "copy patch fallback")
            #expect(
                FileViewerCopy.payload(.oldVersion, text: patch, selection: selection, normalizeLineEndings: true) == "common\nold\n",
                "selected old version autocrlf")
            #expect(
                FileViewerCopy.payload(.newVersion, text: patch, selection: selection, normalizeLineEndings: true) == "common\nnew\n",
                "selected new version autocrlf")
            #expect(FileViewerCopy.payload(.oldVersion, text: patch)?.contains("--- a/f\n+++ b/f") == true, "no-selection headers and triples retained")
            #expect(FileViewerCopy.payload(.selection, text: patch) == nil, "Copy no-selection no-op")
            #expect(FileViewerCopy.payload(.oldVersion, text: "+new", selection: NSRange(location: 0, length: 4)) == "", "missing old side copies empty text")
            #expect(FileViewerCopy.payload(.newVersion, text: "-old", selection: NSRange(location: 0, length: 4)) == "", "missing new side copies empty text")
            let partial = NSRange(location: (patch as NSString).range(of: "new").location + 1, length: 2)
            #expect(FileViewerCopy.payload(.selection, text: patch, selection: partial) == "ew", "mid-line artificial prefix")
            for normalize in [false, true] {
                #expect(
                    FileViewerCopy.payload(.newVersion, text: "é\r\n日本", isDiff: false, normalizeLineEndings: normalize) == (normalize ? "é\n日本" : "é\r\n日本"),
                    "encoded/plain copy \(normalize)")
            }
            #expect(
                FileViewerCopy.payload(.newVersion, text: "@@ -1 +1 @@\n+last", selection: NSRange(location: 12, length: 5)) == "last", "no terminal newline")
        }

        @Test("Binary") static func binary() {
            let data = Data([0, 10, 13, 65, 0x7f, 0x80, 0xe9])
            let decoded = FileContentDecoder.decode(data, path: "bytes.bin", requestedEncoding: .automatic, configuredEncoding: .utf8)
            #expect(
                decoded.kind == .binary && decoded.data == data && decoded.text.hasPrefix("Binary file: bytes.bin\n\n7 bytes:\n\n0000   00 0A 0D 41 7F 80 E9"),
                "binary safe detection/header/X4/X2")
            #expect(decoded.text.hasSuffix("...A..é" + String(repeating: " ", count: 10)), "control characters and Latin-1 display")
            let long = FileContentDecoder.hexDump(Data(repeating: 0, count: 5000), path: "large.bin")
            #expect(long.hasSuffix("[Truncated]") && long.contains("0FF0   ") && !long.contains("1000   "), "4096 byte truncation")
            #expect(FileContentDecoder.hexDump(Data(), path: "empty").isEmpty, "empty dump")
            let mb = FileContentDecoder.hexDump(Data(repeating: 0, count: 110_000), path: "mb.bin")
            #expect(mb.contains(" MB / "), "MB threshold")
            let image = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            #expect(FileContentDecoder.decode(image, path: "image.png", requestedEncoding: .automatic).kind == .image, "image route preserved")
            #expect(FileViewerCopy.payload(.oldVersion, text: decoded.text, isDiff: false) == decoded.text, "binary copies representation, never raw decode")
        }

        @Test("Repository") static func repository() async throws {
            let f = try FileStatusFixture.make()
            defer { f.remove() }
            try f.write("tracked", "base\n")
            try f.write("mixed/tracked", "base\n")
            try f.write(".gitignore", "ignored*\npartial/ignored/\n")
            try f.commitAll("base")
            try f.git(["config", "status.showUntrackedFiles", "normal"])
            for path in [
                "newdir/a.txt", "newdir/sub/b.txt", "newdir/sub/space name", "newdir/日本/é", "mixed/new", "partial/kept/a", "ignored-file", "partial/ignored/a",
            ] { try f.write(path, "new\n") }
            for index in 0..<300 { try f.write("many/\(index)/file", "x") }
            try FileManager.default.createDirectory(at: f.repo.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: f.repo.appendingPathComponent("link").path, withDestinationPath: "newdir")
            let module = GitRepositoryModule(repositoryURL: f.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            let status = try await module.fileStatusDiff(
                first: .index, second: .workingDirectory, parentToSecond: nil, showSkipWorktree: false, showUntracked: true)
            let paths = Set(status.map(\.path))
            #expect(
                paths.count == 307 && paths.contains("newdir/sub/b.txt") && paths.contains("newdir/日本/é") && paths.contains("link")
                    && !paths.contains("newdir/") && !paths.contains("empty/") && !paths.contains("ignored-file"), "expanded nested status \(paths.count)")
            #expect(status.allSatisfy { !$0.isTracked && $0.changeType == .added && $0.staged == .workTree }, "classification")
            try f.write("newdir/added", "a")
            try FileManager.default.removeItem(at: f.repo.appendingPathComponent("newdir/a.txt"))
            let refreshed = Set(
                try await module.fileStatusDiff(first: .index, second: .workingDirectory, parentToSecond: nil, showSkipWorktree: false, showUntracked: true)
                    .map(\.path))
            #expect(refreshed.contains("newdir/added") && !refreshed.contains("newdir/a.txt"), "live refresh content additions/deletions")
            let hidden = try await module.fileStatusDiff(
                first: .index, second: .workingDirectory, parentToSecond: nil, showSkipWorktree: false, showUntracked: false)
            #expect(hidden.isEmpty, "untracked option disabled")
            for autocrlf in ["false", "input", "true"] {
                try f.git(["config", "core.autocrlf", autocrlf])
                try f.write("tracked", "changed\r\n")
                let diff = try await module.loadFileStatusDiff(
                    group: .init(first: .index, second: .workingDirectory, summary: "", files: []), file: item("tracked"), options: FileDiffOptions(),
                    grep: GitGrepOptions())
                if case .diff(let value) = diff {
                    #expect(value?.normalizesCopyLineEndings == (autocrlf == "true"), "repository copy config \(autocrlf)")
                } else {
                    Issue.record("ordinary file retains patch")
                }
            }
            try f.git(["config", "core.autocrlf", "false"])
            for path in ["binary", "removed.bin", "image.png"] {
                let bytes = path == "image.png" ? Data([0x89, 0x50, 0x4e, 0x47, 0, 1]) : Data([0, 1, 2, 0xff])
                try bytes.write(to: f.repo.appendingPathComponent(path))
            }
            try f.commitAll("binaries")
            let head = try f.head()
            try Data([0, 5, 6]).write(to: f.repo.appendingPathComponent("binary"))
            try Data([0, 7, 8]).write(to: f.repo.appendingPathComponent("added.bin"))
            try FileManager.default.removeItem(at: f.repo.appendingPathComponent("removed.bin"))
            let binary = try await module.loadFileStatusDiff(
                group: .init(first: .index, second: .workingDirectory, summary: "", files: []), file: item("binary"), options: FileDiffOptions(),
                grep: GitGrepOptions())
            if case .diff(let value) = binary { #expect(value?.lines.contains { $0.text.contains("Binary files") } == true, "binary patch representation") }
            let old = try await module.loadFileData(path: "binary", at: .object(head))
            let new = try await module.loadFileData(path: "binary", at: .workingDirectory)
            #expect(old == Data([0, 1, 2, 0xff]) && new == Data([0, 5, 6]), "old/new binary bytes acquisition")
            let added = try await module.loadFileData(path: "added.bin", at: .workingDirectory)
            #expect(added == Data([0, 7, 8]), "added binary existing side")
            let removed = try await module.loadFileData(path: "removed.bin", at: .object(head))
            #expect(removed == old, "deleted binary old side")
            do {
                _ = try await module.loadFileData(path: "removed.bin", at: .workingDirectory)
                Issue.record("missing side fails")
            } catch {}
            let destination = f.root.appendingPathComponent("export.bin")
            try await module.exportFile(path: "binary", at: .object(head), to: destination)
            let exported = try Data(contentsOf: destination)
            #expect(exported == old, "shared binary-safe materialization")
        }

        @Test("Submodules") static func submodules() async throws {
            let child = try FileStatusFixture.make()
            let parent = try FileStatusFixture.make()
            defer {
                child.remove()
                parent.remove()
            }
            func commitChild(_ message: String, _ seconds: Int) async throws {
                try child.git(["add", "-A"])
                let result = try await FileStatusFixtureGit().run(
                    arguments: ["commit", "-qm", message], in: child.repo, standardInput: nil,
                    environment: ["GIT_AUTHOR_DATE": "\(seconds) +0000", "GIT_COMMITTER_DATE": "\(seconds) +0000"])
                #expect(result.succeeded, "dated submodule commit")
            }
            try child.write("file", "one\n")
            try await commitChild("base body", 1_700_000_000)
            let old = try child.head()
            try child.write("file", "two\n")
            try await commitChild("advanced body", 1_700_000_200)
            let new = try child.head()
            var sides: [(ObjectID, SubmoduleDiffSummary.Change)] = []
            for (name, timestamp, expected) in [("older-side", 1_700_000_100, SubmoduleDiffSummary.Change.older), ("newer-side", 1_700_000_300, .newer)] {
                try child.git(["checkout", "-qb", name, old.string])
                try child.write("file", name + "\n")
                try await commitChild(name, timestamp)
                sides.append((try child.head(), expected))
            }
            try child.git(["checkout", "-q", "main"])
            try parent.git(["-c", "protocol.file.allow=always", "submodule", "add", child.repo.path, "nested child"])
            try parent.git(["-C", "nested child", "checkout", "--detach", old.string])
            try parent.commitAll("old link")
            let first = try parent.head()
            try parent.git(["-C", "nested child", "checkout", "--detach", new.string])
            try parent.commitAll("new link")
            let second = try parent.head()
            var file = item("nested child")
            file.isSubmodule = true
            let module = GitRepositoryModule(repositoryURL: parent.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            let group = FileStatusGroup(first: .object(first), second: .object(second), summary: "", files: [file])
            let status = try await module.fileStatusSubmodule(group: group, file: file)!
            let summary = status.summary!
            #expect(
                summary.from == old && summary.to == new && summary.added == 1 && summary.removed == 0 && summary.change == .forward,
                "submodule forward identities/counts")
            let text = SubmoduleDiffPresentation.text(summary)
            #expect(
                text.contains("From:\t" + old.string) && text.contains("To:  \t" + new.string) && text.contains("Type: Fast Forward")
                    && text.contains("Commits: 1 added, 0 removed") && text.contains("Differences:\nM\tfile") && text.contains("\t\tadvanced body"),
                "full upstream summary")
            let content = try await module.loadFileStatusDiff(group: group, file: file, options: FileDiffOptions(), grep: GitGrepOptions())
            if case .diff(let diff) = content {
                #expect(
                    diff?.submoduleSummary == summary && diff?.lines.contains { $0.text.hasPrefix("Subproject commit") } == false,
                    "typed summary replaces patch")
            }
            let reverse = try await module.fileStatusSubmodule(
                group: .init(first: .object(second), second: .object(first), summary: "", files: [file]), file: file)
            #expect(reverse?.summary?.change == .rewind && reverse?.summary?.removed == 1, "rewind")
            for (side, expected) in sides {
                try parent.git(["-C", "nested child", "checkout", "--detach", side.string])
                try parent.commitAll("diverged link")
                let sideRevision = try parent.head()
                let diverged = try await module.fileStatusSubmodule(
                    group: .init(first: .object(second), second: .object(sideRevision), summary: "", files: [file]), file: file)!
                #expect(diverged.summary?.change == expected && diverged.added == 1 && diverged.removed == 1, "diverged \(expected)")
            }
            try parent.git(["reset", "--hard", second.string])
            try parent.git(["-C", "nested child", "checkout", "--detach", new.string])
            let added = try await module.fileStatusSubmodule(group: .init(first: nil, second: .object(first), summary: "", files: [file]), file: file)
            #expect(added?.summary?.change == .added && added?.first == nil && added?.second == old, "new submodule summary")
            try parent.write("nested child/file", "dirty\n")
            let dirty = try await module.fileStatusSubmodule(group: .init(first: .index, second: .workingDirectory, summary: "", files: [file]), file: file)!
            #expect(dirty.summary?.change == .same && dirty.isDirty && dirty.summary?.status.contains("M file") == true, "dirty own status and same commit")
            try parent.git(["submodule", "deinit", "--force", "--", "nested child"])
            let absent = try await module.fileStatusSubmodule(group: group, file: file)!
            #expect(
                absent.summary?.isInitialized == false && absent.added == nil && absent.summary?.change == .modified && absent.first == old
                    && absent.second == new, "uninitialized no false metadata")
            try parent.git(["update-index", "--force-remove", "--", "nested child"])
            try parent.git(["commit", "-qm", "removed link"])
            let removedRevision = try parent.head()
            let removed = try await module.fileStatusSubmodule(
                group: .init(first: .object(second), second: .object(removedRevision), summary: "", files: [file]), file: file)
            #expect(removed?.summary?.change == .removed && removed?.first == new && removed?.second == nil, "removed submodule summary")
            let limited = SubmoduleDiffSummary(
                path: "child", from: old, to: new, change: .forward, isDirty: true, isInitialized: true,
                status: (1...8).map { " M file\($0)" }.joined(separator: "\n"),
                differences: (1...7).map { "M\tfile\($0)" }.joined(separator: "\n"))
            let limitedText = SubmoduleDiffPresentation.text(limited, limitOutput: true)
            #expect(
                limitedText.contains("3\tmore changes") && limitedText.contains("2 more differences") && !limitedText.contains("file8"),
                "tooltip limits independently")
            #expect(
                SubmoduleDiffPresentation.relativeDate(now: Date(timeIntervalSince1970: 14 * 86_400), date: Date(timeIntervalSince1970: 0)) == "2 weeks ago",
                "upstream relative week semantics")
        }

        @Test("Copy repository") static func copyRepository() async throws {
            let f = try FileStatusFixture.make()
            defer { f.remove() }
            for (path, text) in [
                ("modified", "old\nshared\n"), ("deleted", "deleted\n"), ("renamed", "same\n"),
                ("copied", "copy\nline\n"), ("no-newline", "old"),
            ] { try f.write(path, text) }
            try Data([0x63, 0x61, 0x66, 0xe9, 10]).write(to: f.repo.appendingPathComponent("latin"))
            try f.commitAll("old contents")
            let old = try f.head()
            try f.write("modified", "new\nshared\n")
            try f.write("added", "added\n")
            try f.write("no-newline", "new")
            try f.git(["rm", "--", "deleted"])
            try f.git(["mv", "--", "renamed", "new name é"])
            try f.write("copy name", "copy\nline\n")
            try f.write("copied", "changed source\n")
            try Data([0x63, 0x61, 0x66, 0xe9, 32, 0x6e, 0x65, 0x75, 0x66, 10]).write(to: f.repo.appendingPathComponent("latin"))
            try f.commitAll("new contents")
            let new = try f.head()
            let files = [
                item("modified"), item("added", type: .added), item("deleted", type: .deleted),
                item("new name é", old: "renamed", type: .renamed), item("copy name", old: "copied", type: .copied), item("no-newline"), item("latin"),
            ]
            let module = GitRepositoryModule(repositoryURL: f.repo, git: FileStatusFixtureGit())
            _ = try await module.loadRepositoryState()
            for autocrlf in ["false", "input", "true"] {
                try f.git(["config", "core.autocrlf", autocrlf])
                for file in files {
                    var options = FileDiffOptions()
                    if file.path == "latin" { options.textEncoding = .westernISO88591 }
                    let content = try await module.loadFileStatusDiff(
                        group: .init(first: .object(old), second: .object(new), summary: "", files: []), file: file, options: options, grep: GitGrepOptions())
                    guard case .diff(let diff?) = content else {
                        Issue.record("copy fixture loaded \(file.path)")
                        continue
                    }
                    #expect(diff.normalizesCopyLineEndings == (autocrlf == "true"), "copy \(file.path) config")
                    let patch = diff.lines.map(\.patchText).joined(separator: "\n")
                    #expect(FileViewerCopy.payload(.patch, text: patch) == patch, "full patch exact \(file.path)")
                    if let hunk = diff.lines.firstIndex(where: { $0.kind == .hunk }), hunk + 1 < diff.lines.count {
                        let rows = IndexSet(integersIn: (hunk + 1)..<diff.lines.count)
                        let selection = FileViewerCopy.selectedRange(lines: diff.lines, rows: rows)!
                        let selectedPatch = FileViewerCopy.payload(.patch, text: patch, selection: selection)!
                        #expect(!selectedPatch.contains("diff --git") && selectedPatch != patch, "subset patch \(file.path)")
                        let previous =
                            FileViewerCopy.payload(.oldVersion, text: patch, selection: selection, normalizeLineEndings: diff.normalizesCopyLineEndings) ?? ""
                        let next =
                            FileViewerCopy.payload(.newVersion, text: patch, selection: selection, normalizeLineEndings: diff.normalizesCopyLineEndings) ?? ""
                        if file.path == "modified" { #expect(previous == "old\nshared\n" && next == "new\nshared\n", "real old/new text") }
                        if file.path == "added" { #expect(previous.isEmpty && next == "added\n", "added missing side") }
                        if file.path == "deleted" { #expect(previous == "deleted\n" && next.isEmpty, "deleted missing side") }
                        if file.path == "latin" { #expect(previous == "café\n" && next == "café neuf\n", "encoded copy") }
                        if file.path == "no-newline" {
                            #expect(previous.contains("old") && next.contains("new") && next.contains("No newline"), "displayed no-newline marker preserved")
                        }
                    }
                    if file.path == "new name é" {
                        let target = patch.components(separatedBy: "\n").first { $0.hasPrefix("rename to ") }.map {
                            PatchPreviewParser.unquote(String($0.dropFirst(10)))
                        }
                        #expect(patch.contains("rename from renamed") && target == file.path, "rename presentation source")
                    }
                    if file.path == "copy name" {
                        #expect(patch.contains("copy from copied") && patch.contains("copy to copy name"), "copy presentation source")
                    }
                }
            }
            let lines = [
                DiffLine(id: "0", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "first"),
                DiffLine(id: "1", oldLineNumber: nil, newLineNumber: 2, kind: .addition, text: "excluded"),
                DiffLine(id: "2", oldLineNumber: nil, newLineNumber: 3, kind: .addition, text: "last"),
            ]
            let ranges = FileViewerCopy.selectedRanges(lines: lines, rows: IndexSet([0, 2]))
            let selected = ranges.compactMap { FileViewerCopy.payload(.patch, text: lines.map(\.patchText).joined(separator: "\n"), selection: $0) }.joined()
            #expect(selected == "+first\n+last", "discontiguous rows exclude unselected lines")
            let indexData = try await module.loadFileData(path: "latin", at: .index)
            let oldData = try await module.loadFileData(path: "latin", at: .object(old))
            #expect(
                indexData == Data([0x63, 0x61, 0x66, 0xe9, 32, 0x6e, 0x65, 0x75, 0x66, 10]) && oldData == Data([0x63, 0x61, 0x66, 0xe9, 10]),
                "shared index/blob materialization retains encoded bytes")
        }
    }
}

typealias DiffAndFileTreeTests = UIIntegrationTests.DiffAndFileTreeTests
