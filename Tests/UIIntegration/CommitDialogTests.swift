import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Commit dialog")
    enum CommitDialogTests {

        private struct Failure: LocalizedError { let errorDescription: String? }

        @Test("Preferences") private static func preferences() throws {
            let defaults = CommitMessageEditorPreferences()
            #expect(defaults.stageInSuperprojectAfterCommit, "Stage in Superproject defaults to true")
            #expect(defaults.markIllFormedLines, "Mark ill formed lines defaults to true")
            #expect(!defaults.showsSelectionFilter, "selection filter hidden by default")
            #expect(!defaults.messageEditorWordWrap, "MessageEditorWordWrap defaults to false")
            let decoded = try JSONDecoder().decode(CommitMessageEditorPreferences.self, from: Data("{}".utf8))
            #expect(decoded == defaults, "missing keys decode to upstream defaults")
            let suite = "GitExtensionsMac.CommitDialogTests.\(UUID().uuidString)"
            let userDefaults = UserDefaults(suiteName: suite)!
            defer { userDefaults.removePersistentDomain(forName: suite) }
            let store = AppSettingsStore(defaults: userDefaults)
            #expect(store.commitMessageEditorPreferences == defaults, "fresh store uses defaults")
            var changed = defaults
            changed.stageInSuperprojectAfterCommit = false
            changed.markIllFormedLines = false
            changed.showsSelectionFilter = true
            changed.messageEditorWordWrap = true
            store.saveCommitMessageEditorPreferences(changed)
            #expect(AppSettingsStore(defaults: userDefaults).commitMessageEditorPreferences == changed, "preferences persist across stores")
            let existingCommitPreferences = store.commitPreferences
            #expect(AppSettingsStore(defaults: userDefaults).commitPreferences == existingCommitPreferences, "commit preferences unaffected")
            let commit = ApplicationHotkeys.definitions.filter { $0.category == "Commit" }
            #expect(
                commit.first { $0.id == "commit.toggleSelectionFilter" }?.defaultChord == ApplicationKeyChord("f", .command),
                "ToggleSelectionFilter is Cmd+F (upstream Ctrl+F)")
            #expect(
                commit.first { $0.id == "commit.filter" }?.defaultChord == ApplicationKeyChord("f", [.command, .option]),
                "existing file-list filter keeps its own chord")
            let chords = commit.map(\.defaultChord).filter { !$0.key.isEmpty }
            #expect(Set(chords.map { "\($0.key)/\($0.modifiers)" }).count == chords.count, "commit hotkey chords are unique")
        }

        @Test("Word wrapper") private static func wordWrapper() throws {
            #expect(CommitWordWrapper.wrapSingleLine("aaa bbb ccc", limit: 8) == "aaa bbb\nccc", "wrapped lines stay below the limit")
            #expect(CommitWordWrapper.wrapSingleLine("aaa bbb ccc", limit: 7) == "aaa\nbbb\nccc", "a line reaching the limit wraps")
            #expect(CommitWordWrapper.wrapSingleLine("averyveryverylongword x", limit: 5) == "averyveryverylongword\nx", "a single long word is not split")
            #expect(CommitWordWrapper.wrapSingleLine("a\tb", limit: 72) == "a b", "whitespace characters become word separators")
            #expect(CommitWordWrapper.wrapSingleLine("a  b", limit: 72) == "a  b", "consecutive separators yield empty words")
            #expect(CommitWordWrapper.bodyLineLimit(configured: 0) == 72 && CommitWordWrapper.bodyLineLimit(configured: 40) == 40, "72 fallback when unset")
            let subject = String(repeating: "s", count: 90)
            let body = "one two three four five six seven eight nine ten"
            let wrapped = CommitWordWrapper.wrapBody("\(subject)\n\n\(body)\nshort", limit: 20)
            #expect(wrapped == "\(subject)\n\none two three four\nfive six seven\neight nine ten\nshort", "body wrapped, subject preserved: \(wrapped)")
            #expect(
                CommitWordWrapper.wrapBody("s\n" + String(repeating: "x", count: 20), limit: 20) == "s\n" + String(repeating: "x", count: 20),
                "a line exactly at the limit is left alone")
            #expect(CommitWordWrapper.wrapBody("subject only", limit: 3) == "subject only", "single-line messages are unchanged")
            #expect(CommitWordWrapper.wrapBody("s\nline one two", limit: 9) == "s\nline one\ntwo", "line 1 is wrapped like the rest of the body")
        }

        @Test("Ill formed lines") private static func illFormedLines() throws {
            let fifty = String(repeating: "a", count: 50)
            #expect(CommitMessageMarkup.illFormedRanges(in: fifty).isEmpty, "50-char subject is fine")
            #expect(CommitMessageMarkup.illFormedRanges(in: fifty + "bc") == [NSRange(location: 50, length: 2)], "subject overflow after column 50")
            #expect(CommitMessageMarkup.illFormedRanges(in: "s\nx") == [NSRange(location: 2, length: 1)], "any text on line 2")
            #expect(CommitMessageMarkup.illFormedRanges(in: "s\n\n" + String(repeating: "b", count: 72)).isEmpty, "72-char body line is fine")
            #expect(
                CommitMessageMarkup.illFormedRanges(in: "s\n\n" + String(repeating: "b", count: 75)) == [NSRange(location: 3 + 72, length: 3)],
                "body overflow after column 72")
            #expect(
                CommitMessageMarkup.illFormedRanges(in: "é" + String(repeating: "a", count: 50)) == [NSRange(location: 50, length: 1)],
                "columns counted in UTF-16 units like upstream")
            #expect(CommitMessageMarkup.marksBlankFirstLine("\nbody"), "blank first line is marked")
            #expect(
                !CommitMessageMarkup.marksBlankFirstLine("\n") && !CommitMessageMarkup.marksBlankFirstLine("")
                    && !CommitMessageMarkup.marksBlankFirstLine("ab"),
                "blank-first-line mark requires more than one character")
        }

        @Test("Over limit ranges") private static func overLimitRanges() throws {
            let text = "123456789012\nsecond line here\n" + String(repeating: "c", count: 25)
            #expect(
                CommitMessageMarkup.overLimitRanges(in: text, firstLineLimit: 10, bodyLineLimit: 20, secondLineMustBeEmpty: true)
                    == [NSRange(location: 10, length: 2), NSRange(location: 30 + 20, length: 5)],
                "subject and body overflow; line 2 skipped when it must be empty")
            #expect(
                CommitMessageMarkup.overLimitRanges(in: text, firstLineLimit: 10, bodyLineLimit: 10, secondLineMustBeEmpty: false)
                    == [NSRange(location: 10, length: 2), NSRange(location: 13 + 10, length: 6), NSRange(location: 30 + 10, length: 15)],
                "line 2 counts as body otherwise")
            #expect(
                CommitMessageMarkup.overLimitRanges(in: text, firstLineLimit: 0, bodyLineLimit: 0, secondLineMustBeEmpty: false).isEmpty,
                "zero limits disable colouring")
        }

        @Test("Markup coexistence") private static func markupCoexistence() throws {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            let view = CommitMessageTextView(frame: scroll.bounds)
            view.isRichText = false
            scroll.documentView = view
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            defer { window.close() }
            let text = String(repeating: "w", count: 60) + "\nx\nmisspelt word"
            view.string = text
            view.setSelectedRange(NSRange(location: 5, length: 3))
            let typing = view.typingAttributes
            let storageBefore = view.textStorage!.attributes(at: 0, effectiveRange: nil)
            let spellingRange = NSRange(location: 64, length: 8)
            view.layoutManager!.addTemporaryAttribute(
                .spellingState, value: NSAttributedString.SpellingState.spelling.rawValue, forCharacterRange: spellingRange)
            view.illFormedRanges = CommitMessageMarkup.illFormedRanges(in: text)
            view.marksBlankFirstLine = CommitMessageMarkup.marksBlankFirstLine(text)
            let limits = CommitMessageMarkup.overLimitRanges(in: text, firstLineLimit: 50, bodyLineLimit: 5, secondLineMustBeEmpty: false)
            view.applyOverLimitRanges(limits)
            view.applyOverLimitRanges(limits)
            view.display()
            #expect(view.string == text, "markup does not change the message")
            #expect(view.selectedRange() == NSRange(location: 5, length: 3), "markup preserves the selection")
            #expect(NSDictionary(dictionary: view.typingAttributes).isEqual(to: typing), "markup preserves typing attributes")
            #expect(
                NSDictionary(dictionary: view.textStorage!.attributes(at: 55, effectiveRange: nil)).isEqual(to: storageBefore), "text storage carries no markup"
            )
            let layout = view.layoutManager!
            #expect(layout.temporaryAttribute(.spellingState, atCharacterIndex: 64, effectiveRange: nil) != nil, "spelling state survives")
            #expect(
                layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 55, effectiveRange: nil) as? NSColor == CommitMessageMarkup.overLimitColor,
                "over-limit characters are red")
            #expect(
                layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 10, effectiveRange: nil) == nil, "in-limit characters keep the default colour")
            #expect(
                view.illFormedRanges
                    == [NSRange(location: 50, length: 10), NSRange(location: 61, length: 1), NSRange(location: 63 + 72 - 72, length: 0)].filter {
                        $0.length > 0
                    },
                "ill-formed ranges coexist with over-limit colouring")
            view.applyOverLimitRanges([])
            #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 55, effectiveRange: nil) == nil, "colouring clears when limits change")
            view.string = "abc"
            #expect(view.string == "abc", "string override assigns")
            var assigned = 0
            view.onStringAssigned = { assigned += 1 }
            view.string = "next"
            #expect(assigned == 1, "programmatic assignment notifies for re-formatting")
            #expect(view.rangeForUserCompletion == NSRange(location: 0, length: 0) || view.selectedRange().location == 4, "completion range computed")
            view.setSelectedRange(NSRange(location: 4, length: 0))
            #expect(view.rangeForUserCompletion == NSRange(location: 0, length: 4), "completion uses WordAtCursorExtractor bounds")
            view.string = "Fix obj._fie"
            view.setSelectedRange(NSRange(location: 12, length: 0))
            #expect(view.rangeForUserCompletion == NSRange(location: 8, length: 4), "leading underscore kept, dot after identifier excluded")
        }

        @Test("Conventional commits") private static func conventionalCommits() throws {
            let vectors: [(String, Int, Bool, String, Int)] = [
                ("", 0, false, "feat: ", 6),
                ("text", 3, false, "feat: text", 9),
                ("", 0, true, "feat(): ", 5),
                ("text", 3, true, "feat(): text", 5),
                ("fix: ", 0, false, "feat: ", 6),
                ("fix: text", 3, false, "feat: text", 6),
                ("fix: ", 0, true, "feat(): ", 5),
                ("fix: text", 3, true, "feat(): text", 5),
                ("fix(scope): ", 0, true, "feat(scope): ", 13),
                ("fix(scope): text", 14, true, "feat(scope): text", 15),
            ]
            for (message, position, scope, expected, expectedPosition) in vectors {
                let result = ConventionalCommitPrefixer.prefixOrReplace(keyword: "feat", message: message, selectionStart: position, insertScope: scope)
                #expect(
                    result.title == expected && result.selectionStart == expectedPosition,
                    "upstream FormCommitTests vector \(message)/\(position)/\(scope): \(result)")
            }
            let replaced = ConventionalCommitPrefixer.prefixOrReplace(keyword: "docs", message: "fix!: breaking", selectionStart: 14, insertScope: false)
            #expect(
                replaced.title == "docs!: breaking" && replaced.selectionStart == 15,
                "'!' marker keeps message and moves caret by the keyword delta: \(replaced)")
            let bare = ConventionalCommitPrefixer.prefixOrReplace(keyword: "fix", message: "feat", selectionStart: 4, insertScope: false)
            #expect(bare.title == "fix: " && bare.selectionStart == 5, "bare keyword replaced")
            let word = ConventionalCommitPrefixer.prefixOrReplace(keyword: "feat", message: "feature flags", selectionStart: 0, insertScope: false)
            #expect(word.title == "feat: feature flags", "a word merely starting with a type is not replaced")
            let applied = ConventionalCommitPrefixer.apply(keyword: "ci", message: "fix: subject\n\nbody line", selectionStart: 0, insertScope: false)
            #expect(applied.message == "ci: subject\n\nbody line" && applied.selectionStart == 4, "only the subject line changes: \(applied)")
            #expect(ConventionalCommitPrefixer.apply(keyword: "feat", message: "", selectionStart: 0, insertScope: false).message == "feat: ", "empty message")
            #expect(ConventionalCommitPrefixer.appendFooter("Reviewed-by: ", to: "s\nb") == "s\nb\nReviewed-by: ", "footer appended after the last line")
            #expect(ConventionalCommitPrefixer.appendFooter("[skip ci]", to: "") == "\n[skip ci]", "footer on empty message starts on line 2")
            #expect(
                ConventionalCommitPrefixer.headerCommitTypes == ["build", "chore", "ci", "docs", "feat", "fix", "perf", "refactor", "style", "test"],
                "upstream type order")
        }

        @Test("Selection filter logic") private static func selectionFilterLogic() throws {
            let paths = ["src/A.cs", "src/b.txt", "lib/C.CS", "docs/readme.md"]
            #expect(try CommitSelectionFilter.matchingPaths(paths, pattern: #"\.cs$"#) == ["src/A.cs", "lib/C.CS"], "regex matches case-insensitively")
            #expect(try CommitSelectionFilter.matchingPaths(paths, pattern: "^src/") == ["src/A.cs", "src/b.txt"], "regex matches the full relative path")
            #expect(try CommitSelectionFilter.matchingPaths(paths, pattern: "") == paths, "empty filter selects everything like upstream")
            var threw = false
            do { _ = try CommitSelectionFilter.matchingPaths(paths, pattern: "(") } catch {
                threw = true
                #expect(CommitSelectionFilter.errorToolTip(error).hasPrefix("Error "), "invalid expression reported in the tool tip")
            }
            #expect(threw, "invalid regex throws")
            var history: [String] = []
            for index in 0..<12 { history = CommitSelectionFilter.history(history, adding: "f\(index)") }
            #expect(history.count == 10 && history.first == "f11" && history.last == "f2", "history keeps the newest ten at the front: \(history)")
            #expect(CommitSelectionFilter.history(history, adding: "f5") == history, "existing entries are not duplicated or moved")
            #expect(CommitSelectionFilter.history(history, adding: "") == history, "empty filter is not recorded")
            #expect(CommitSelectionFilter.throttle == .milliseconds(250), "250 ms throttle")
        }

        @Test("Selection filter throttle") private static func selectionFilterThrottle() async throws {
            let throttle = CommitSelectionFilterThrottle(delay: .milliseconds(60))
            var performed: [String] = []
            throttle.submit("a") { performed.append($0) }
            try await Task.sleep(for: .milliseconds(20))
            throttle.submit("ab") { performed.append($0) }
            try await Task.sleep(for: .milliseconds(20))
            throttle.submit("abc") { performed.append($0) }
            #expect(performed.isEmpty, "nothing applied while typing continues")
            try await Task.sleep(for: .milliseconds(200))
            #expect(performed == ["abc"], "only the final value is applied after the quiet period: \(performed)")
            throttle.submit("x") { performed.append($0) }
            throttle.cancel()
            try await Task.sleep(for: .milliseconds(120))
            #expect(performed == ["abc"], "cancel drops the pending value")
        }

        @Test("Author status") private static func authorStatus() throws {
            #expect(CommitAuthorStatus.text(committer: "Ann <a@example.com>", author: "") == "Committer Ann <a@example.com>", "committer only")
            #expect(
                CommitAuthorStatus.text(committer: "Ann <a@example.com>", author: "Bob <b@example.com>")
                    == "Committer Ann <a@example.com> Author Bob <b@example.com>",
                "author override appended")
            #expect(CommitAuthorStatus.text(committer: nil, author: "") == "Loading author…", "loading state")
            #expect(CommitAuthorStatus.toolTip == "Click to change committer information.", "upstream runtime tooltip")
            let button = CommitAuthorStatusButton()
            button.statusText = "Committer X"
            #expect(button.toolTip == CommitAuthorStatus.toolTip && button.accessibilityRole() == .link, "link-like control")
            #expect(button.attributedTitle.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil, "no underline until hover")
            button.mouseEntered(with: NSEvent())
            #expect(button.attributedTitle.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil, "hover underlines")
            button.mouseExited(with: NSEvent())
            let suite = "GitExtensionsMac.CommitDialogTests.settings.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let remembered = SettingsViewController.lastSelectedPage
            defer {
                SettingsViewController.lastSelectedPage = remembered
                defaults.removePersistentDomain(forName: suite)
            }
            let controller = SettingsViewController(
                store: AppSettingsStore(defaults: defaults), source: nil, initialPage: CommitAuthorStatus.settingsPage, repositoryChanged: {})
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            _ = controller.view
            #expect(controller.currentCategoryID == "git_config", "author link opens Settings at Git ▸ Config: \(controller.currentCategoryID)")
        }

        @Test("Word at cursor extractor") private static func wordAtCursorExtractor() throws {
            let extractor = CommitWordAtCursorExtractor()
            let extract: [(String, String)] = [
                (".git", ".git"), ("Add .g", ".g"), ("Add.g", "g"), ("Add,git", "git"), ("Add (.git", ".git"), ("Introduce Tes", "Tes"),
                ("Add).git", "git"), ("[Add].git", "git"), ("Introduce .babeljs]", ""), ("func().otherFun", "otherFun"),
                ("func().other_fun", "other_fun"), ("obj._field", "_field"), ("func(type init_", "init_"),
            ]
            for (text, expected) in extract {
                #expect(extractor.extract(text, index: (text as NSString).length - 1) == expected, "Extract \(text)")
            }
            let bounds: [(String, Int, Int, Int)] = [
                ("", -2, 0, 0), ("", -1, 0, 0), ("", 0, 0, 0), ("", 1, 0, 0),
                ("_obj.f", -2, 0, 0), ("_obj.f", -1, 0, 0), ("_obj.f", 0, 0, 4), ("_obj.f", 1, 0, 4), ("_obj.f", 2, 0, 4), ("_obj.f", 3, 0, 4),
                ("_obj.f", 4, 4, 1), ("_obj.f", 5, 5, 1), ("_obj.f", 6, 5, 1), ("_obj.f", 7, 5, 1),
                ("0  3", 0, 0, 1), ("0  2", 1, 1, 1), ("0  2", 2, 2, 1), ("0  2", 3, 3, 1),
            ]
            for (text, index, start, length) in bounds {
                let result = extractor.wordBounds(text, index: index)
                #expect(result.start == start && result.length == length, "GetWordBounds \(text)/\(index): \(result)")
            }
            let starts: [(String, Int, Int)] = [
                ("", -2, -1), ("", -1, -1), ("", 0, -1), ("", 1, -1), ("012", -2, -1), ("012", -1, -1), ("012", 0, 0), ("012", 1, 0), ("012", 2, 0),
                ("012", 3, 0), ("012", 4, 0), ("01A34", 5, 0), ("01a34", 5, 0), ("01_34", 5, 0), ("01 34", 5, 3), ("01.34", 5, 3), ("01 .4", 5, 3),
                ("01..4", 5, 3), ("01).4", 5, 4), ("01].4", 5, 4), ("012.4", 5, 4), ("012.4", 4, 4), ("012.4", 3, 4), ("012/4", 3, 4),
                ("012.4", 2, 0), ("012.4", 1, 0), ("012.4", 0, 0),
            ]
            for (text, index, expected) in starts {
                #expect(extractor.findStartOfWord(text, index: index) == expected, "FindStartOfWord \(text)/\(index)")
            }
            let ends: [(String, Int, Int)] = [
                ("", -2, -1), ("", -1, -1), ("", 0, 0), ("", 1, 0), ("012", -2, -1), ("012", -1, -1), ("012", 0, 3), ("012", 1, 3), ("012", 2, 3),
                ("012", 3, 3), ("012", 4, 3), ("01A34", 0, 5), ("01a34", 0, 5), ("01_34", 0, 5), ("01 34", 0, 2), ("01/34", 0, 2), ("01/34", 1, 2),
                ("01/34", 2, 2), ("01/34", 3, 5), ("01/34", 4, 5), ("/12", 0, 0), ("/12", 1, 3), ("01/", 0, 2), ("01/", 1, 2), ("01/", 2, 2), ("01/", 3, 3),
            ]
            for (text, index, expected) in ends {
                #expect(extractor.findEndOfWord(text, index: index) == expected, "FindEndOfWord \(text)/\(index)")
            }
            let words: [(String, String, Bool)] = [
                ("CamelHump", "CH", true), ("CamelHump", "ch", true), ("CamelHump", "cH", true), ("CamelHump", "Ch", true), ("CamelHump", "Ca", true),
                ("CamelHump", "ca", true), ("CamelHump", "CamelH", true), ("CamelHump", "CX", false), ("MyCamelHump", "MCH", true),
                ("MyCamelHump", "mch", true), ("MyCamelHump", "CH", false), ("Identifier", "i", true), ("Identifier", "I", true),
                ("Identifier", "id", true), ("Identifier", "Id", true),
            ]
            for (word, typed, expected) in words {
                #expect(CommitAutoCompleteWord(word).matches(typed) == expected, "AutoCompleteWord \(word)/\(typed)")
            }
        }

        @Test("Auto complete words") private static func autoCompleteWords() throws {
            let regexes = CommitAutoCompleteRegexes.parse(CommitAutoCompleteRegexes.defaultDefinitions.components(separatedBy: .newlines))
            #expect(
                Set(regexes.keys).isSuperset(of: [
                    ".asm", ".au3", ".auh", ".bas", ".frm", ".cls", ".bat", ".build", ".cbl", ".cpy", ".c", ".cc", ".cpp", ".cxx",
                    ".asp", ".aspx", ".cs", ".h", ".hpp", ".hxx", ".html", ".java", ".groovy", ".js", ".pas", ".php", ".cgi",
                    ".pl", ".pm", ".ps1", ".py", ".pyw", ".rb", ".sd", ".vb", ".vb6", ".xaml",
                ]) && regexes.count == 37,
                "all 21 upstream groups and their extensions: \(regexes.count)")
            func words(_ path: String, _ text: String) -> Set<String> {
                Set(
                    CommitAutoCompleteRegexes.words(
                        for: ChangedFile(id: path, path: path, oldPath: nil, changeType: .modified, additions: 0, deletions: 0),
                        text: text, regexes: regexes))
            }
            #expect(
                words("src/Widget.cs", "+public class Widget\n+    new Helper();\n+using System.Text;").isSuperset(of: ["Widget", "Helper", "System.Text"]),
                "C# identifiers")
            #expect(
                words("tool.py", "def helper_func():\n    pass\nclass Later:").contains("helper_func")
                    && !words("tool.py", "def helper_func():\n    pass\nclass Later:").contains("Later"),
                "^ anchors the start of the text like .NET single-line mode")
            #expect(words("app.js", "this.render = function draw(a) {").isSuperset(of: ["render", "draw"]), "JavaScript functions")
            #expect(words("x.php", "$a->callMe(); Foo::bar();").isSuperset(of: ["callMe", "bar"]), "PHP members")
            #expect(words("readme.md", "public class Nothing").isSubset(of: ["readme.md", "readme"]), "unknown extensions only add file names")
            #expect(words("Widget.CS", "public class Upper").isSubset(of: ["Widget.CS", "Widget"]), "extension lookup is case-sensitive like upstream")
            let renamed = CommitAutoCompleteRegexes.words(
                for: ChangedFile(id: "n", path: "new/Name.txt", oldPath: "old/Former.txt", changeType: .renamed, additions: 0, deletions: 0),
                text: nil, regexes: regexes)
            #expect(Set(renamed) == ["Name.txt", "Name", "Former", "Former.txt"], "current and old file names: \(renamed)")
            var submodule = ChangedFile(id: "s", path: "deps/lib.cs", oldPath: nil, changeType: .modified, additions: 0, deletions: 0)
            submodule.isSubmodule = true
            #expect(
                CommitAutoCompleteRegexes.words(for: submodule, text: "public class Hidden", regexes: regexes) == ["lib.cs"],
                "submodules contribute only their name")
            #expect(
                CommitAutoCompleteRegexes.fileExtension("dir/.gitignore") == ".gitignore" && CommitAutoCompleteRegexes.fileExtension("a.") == ""
                    && CommitAutoCompleteRegexes.fileExtension("Makefile") == "" && CommitAutoCompleteRegexes.fileNameWithoutExtension("a.b.cs") == "a.b",
                "Path.GetExtension semantics")
            #expect(
                CommitAutoCompleteRegexes.metadataKeywords == ["Co-authored-by: ", "Signed-off-by: ", "BREAKING CHANGE: ", "Reviewed-by: ", "Tested-by: "],
                "metadata trailers")
            let diff = FileDiff(
                id: "d", fileID: "d",
                lines: [
                    DiffLine(id: "1", oldLineNumber: nil, newLineNumber: nil, kind: .hunk, text: "@@ -1 +1 @@"),
                    DiffLine(id: "2", oldLineNumber: 1, newLineNumber: nil, kind: .deletion, text: "old"),
                    DiffLine(id: "3", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "new"),
                    DiffLine(id: "4", oldLineNumber: 2, newLineNumber: 2, kind: .context, text: "same"),
                ])
            #expect(CommitAutoCompleteRegexes.patchText(path: "p.cs", diff: diff) == "diff --git a/p.cs b/p.cs\n@@ -1 +1 @@\n-old\n+new\n same", "patch text")
            #expect(CommitAutoCompleteRegexes.contentText(diff: diff) == "new\nsame", "untracked content text")
        }

        @Test("Auto complete regex override") private static func autoCompleteRegexOverride() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CommitParity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("AutoCompleteRegexes.txt")
            #expect(CommitAutoCompleteRegexes.load(overrideURL: file).count == 37, "defaults used when no override file exists")
            try ".swift, .kt = func\\s+(\\w+)\n\nnot-a-definition\n.cs = class\\s+(\\w+)\n.cs = struct\\s+(\\w+)\n.bad = ([unclosed\n".write(
                to: file, atomically: true, encoding: .utf8)
            let overridden = CommitAutoCompleteRegexes.load(overrideURL: file)
            #expect(Set(overridden.keys) == [".swift", ".kt", ".cs"], "override file replaces the defaults: \(overridden.keys.sorted())")
            let swift = CommitAutoCompleteRegexes.captures(in: "func makeThing() {}", expression: overridden[".swift"]!)
            #expect(swift == ["makeThing"], "override regex used")
            #expect(
                CommitAutoCompleteRegexes.captures(in: "class A struct B", expression: overridden[".cs"]!) == ["A"],
                "first definition wins for duplicate extensions")
            #expect(
                CommitAutoCompleteRegexes.overrideFileURL.path.hasSuffix("Application Support/GitExtensionsMac/AutoCompleteRegexes.txt"),
                "app-data override location")
        }

        @Test("Auto complete from repository") private static func autoCompleteFromRepository() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.repository("words")
            try "public class Original\n{\n}\n".write(to: repo.appendingPathComponent("Widget.cs"), atomically: true, encoding: .utf8)
            _ = try fixture.git(["add", "."], in: repo)
            _ = try fixture.git(["commit", "-q", "-m", "base"], in: repo)
            try "public class Original\n{\n    public void RenderWidget() { }\n}\n".write(
                to: repo.appendingPathComponent("Widget.cs"), atomically: true, encoding: .utf8)
            try "def untracked_helper():\n    return 1\n".write(to: repo.appendingPathComponent("tool.py"), atomically: true, encoding: .utf8)
            try "public class Staged { }\n".write(to: repo.appendingPathComponent("Staged.cs"), atomically: true, encoding: .utf8)
            _ = try fixture.git(["add", "Staged.cs"], in: repo)
            let module = GitRepositoryModule(repositoryURL: repo)
            let state = try await module.loadRepositoryState()
            let artificial = RevisionCommitBuilder.artificialRevisions(headID: state.commitContext.headID)
            let worktree = try await module.loadRevisionDetails(for: artificial.first { $0.kind == .workingDirectory }!)
            let index = try await module.loadRevisionDetails(for: artificial.first { $0.kind == .index }!)
            let files = worktree.files.map { (file: $0, kind: Commit.Kind.workingDirectory) } + index.files.map { (file: $0, kind: Commit.Kind.index) }
            let regexes = CommitAutoCompleteRegexes.parse(CommitAutoCompleteRegexes.defaultDefinitions.components(separatedBy: .newlines))
            let words = await CommitAutoCompleteRegexes.collectWords(files: files, regexes: regexes) { file, kind in
                try? await module.loadDiff(for: artificial.first { $0.kind == kind }!, file: file, options: FileDiffOptions(contextLines: 5))
            }
            #expect(
                Set(words).isSuperset(of: ["RenderWidget", "Widget.cs", "Widget", "untracked_helper", "tool.py", "Staged", "Staged.cs"]),
                "identifiers from tracked diffs, untracked content and staged changes: \(words)")
            #expect(!words.contains("return"), "untracked text is the file content, not a patch")
        }

        @Test("Superproject staging") private static func superprojectStaging() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let (superproject, submodule) = try fixture.superprojectWithSubmodule()
            let plain = try fixture.repository("plain")
            let plainModule = GitRepositoryModule(repositoryURL: plain)
            _ = try await plainModule.loadRepositoryState()
            let plainLocation = await plainModule.loadSuperprojectSubmodule()
            #expect(plainLocation == nil, "ordinary repository has no superproject")
            let nested = superproject.appendingPathComponent("nested")
            _ = try fixture.git(["init", "-q", "-b", "main", nested.path], in: superproject)
            let nestedModule = GitRepositoryModule(repositoryURL: nested)
            _ = try await nestedModule.loadRepositoryState()
            let nestedLocation = await nestedModule.loadSuperprojectSubmodule()
            #expect(nestedLocation == nil, "unregistered nested repository is not a submodule")
            let module = GitRepositoryModule(repositoryURL: submodule)
            _ = try await module.loadRepositoryState()
            let location = await module.loadSuperprojectSubmodule()
            #expect(
                location?.path == "sub" && location?.superprojectURL.resolvingSymlinksInPath().path == superproject.resolvingSymlinksInPath().path,
                "submodule detected: \(String(describing: location))")
            #expect(CommitSuperprojectStaging.target(location: location, preference: false) == nil, "preference off disables staging")
            let target = CommitSuperprojectStaging.target(location: location, preference: true)
            #expect(target != nil, "preference on stages")
            #expect(CommitSuperprojectStaging.shouldStage(target: target, pushRequested: false, pushCompleted: false), "commit without push stages")
            #expect(CommitSuperprojectStaging.shouldStage(target: target, pushRequested: true, pushCompleted: true), "completed push stages")
            #expect(!CommitSuperprojectStaging.shouldStage(target: target, pushRequested: true, pushCompleted: false), "cancelled push does not stage")
            #expect(!CommitSuperprojectStaging.shouldStage(target: nil, pushRequested: false, pushCompleted: false), "no target never stages")

            let failing = RepositoryCommitRequest(
                message: "nothing", mode: .normal, stageAllBeforeCommit: false, allowEmpty: false, signOff: false, author: nil, resetAuthor: false)
            var failed = false
            do { _ = try await module.commit(failing) } catch { failed = true }
            #expect(failed, "commit without staged changes fails")
            #expect(try fixture.git(["diff", "--cached", "--name-only"], in: superproject).isEmpty, "failed commit leaves the superproject index alone")

            try "changed\n".write(to: submodule.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
            let request = RepositoryCommitRequest(
                message: "child change", mode: .normal, stageAllBeforeCommit: true, allowEmpty: false, signOff: false, author: nil, resetAuthor: false)
            _ = try await module.commit(request)
            #expect(try fixture.git(["diff", "--name-only"], in: superproject) == "sub", "superproject sees the moved submodule")
            try await module.stageInSuperproject(target!)
            #expect(try fixture.git(["diff", "--cached", "--name-only"], in: superproject) == "sub", "submodule path staged in the superproject")
            let head = try fixture.git(["rev-parse", "HEAD"], in: submodule)
            #expect(try fixture.git(["ls-files", "--stage", "--", "sub"], in: superproject).hasPrefix("160000 \(head) 0"), "gitlink points at the new commit")
        }

        @Test("Commit dialog superproject") private static func commitDialogSuperproject() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let (superproject, submodule) = try fixture.superprojectWithSubmodule()
            let store = AppSettingsStore.shared
            let savedEditor = store.commitMessageEditorPreferences
            let savedCommit = store.commitPreferences
            defer {
                store.saveCommitMessageEditorPreferences(savedEditor)
                store.saveCommitPreferences(savedCommit)
            }
            var editor = savedEditor
            editor.stageInSuperprojectAfterCommit = true
            store.saveCommitMessageEditorPreferences(editor)
            var commitPreferences = savedCommit
            commitPreferences.closeAfterCommit = true
            commitPreferences.validation = CommitValidationPreferences()
            store.saveCommitPreferences(commitPreferences)

            try "dialog\n".write(to: submodule.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
            _ = try fixture.git(["add", "child.txt"], in: submodule)
            let gitDirectory = URL(fileURLWithPath: try fixture.git(["rev-parse", "--absolute-git-dir"], in: submodule))
            let hook = gitDirectory.appendingPathComponent("hooks/commit-msg")
            try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

            let module = GitRepositoryModule(repositoryURL: submodule)
            _ = try await module.loadRepositoryState()
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            defer { owner.close() }
            var closed = false
            let controller = CommitWorkflowDialog.present(
                source: module, initialMode: .normal, head: nil, draft: nil, owner: owner,
                onRepositoryChanged: { _ in }, onClose: { closed = true })
            let window = controller.window!
            defer { window.close() }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func checkbox() -> NSButton? {
                descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == CommitSuperprojectStaging.title }
            }
            let deadline = ContinuousClock.now + .seconds(20)
            while checkbox()?.isHidden != false
                || !(descendants(window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue.hasPrefix("1/") })
            {
                #expect(ContinuousClock.now < deadline, "dialog loads and shows Stage in Superproject")
                try await Task.sleep(for: .milliseconds(20))
            }
            let stage = checkbox()!
            #expect(stage.state == .on && stage.toolTip == CommitSuperprojectStaging.toolTip, "checked by default with upstream tooltip")
            stage.performClick(nil)
            #expect(!store.commitMessageEditorPreferences.stageInSuperprojectAfterCommit, "unchecking persists")
            stage.performClick(nil)
            #expect(store.commitMessageEditorPreferences.stageInSuperprojectAfterCommit, "re-checking persists")

            let message = descendants(window.contentView!).compactMap { $0 as? CommitMessageTextView }.first!
            message.string = "dialog commit"
            let commitButton = descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Commit" }!
            commitButton.performClick(nil)
            let failureDeadline = ContinuousClock.now + .seconds(20)
            while window.attachedSheet == nil {
                #expect(ContinuousClock.now < failureDeadline, "failed commit reports an error")
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(try fixture.git(["diff", "--cached", "--name-only"], in: superproject).isEmpty, "failed commit does not stage the superproject")
            let sheet = window.attachedSheet!
            window.endSheet(sheet)
            try await Task.sleep(for: .milliseconds(200))

            try FileManager.default.removeItem(at: hook)
            let retryDeadline = ContinuousClock.now + .seconds(20)
            while !commitButton.isEnabled {
                #expect(ContinuousClock.now < retryDeadline, "dialog ready after failure")
                try await Task.sleep(for: .milliseconds(20))
            }
            commitButton.performClick(nil)
            let successDeadline = ContinuousClock.now + .seconds(20)
            while try fixture.git(["diff", "--cached", "--name-only"], in: superproject) != "sub" {
                #expect(ContinuousClock.now < successDeadline, "successful commit stages the submodule in the superproject")
                try await Task.sleep(for: .milliseconds(20))
            }
            let head = try fixture.git(["rev-parse", "HEAD"], in: submodule)
            #expect(try fixture.git(["log", "-1", "--format=%s"], in: submodule) == "dialog commit", "commit created")
            #expect(try fixture.git(["ls-files", "--stage", "--", "sub"], in: superproject).hasPrefix("160000 \(head) 0"), "staged gitlink matches the commit")
            let closeDeadline = ContinuousClock.now + .seconds(10)
            while !closed {
                #expect(ContinuousClock.now < closeDeadline, "close-after-commit behaviour preserved")
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        @Test("Commit dialog file list selection") private static func commitDialogFileListSelection() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.repository("file-list-selection")
            for name in ["a.txt", "b.txt", "c.txt"] { try "x\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            _ = try fixture.git(["add", "."], in: repo)
            _ = try fixture.git(["commit", "-q", "-m", "base"], in: repo)
            for name in ["a.txt", "b.txt", "c.txt"] { try "y\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            let module = GitRepositoryModule(repositoryURL: repo)
            _ = try await module.loadRepositoryState()
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            defer { owner.close() }
            let controller = CommitWorkflowDialog.present(
                source: module, initialMode: .normal, head: nil, draft: nil, owner: owner,
                onRepositoryChanged: { _ in }, onClose: {})
            let window = controller.window!
            defer { window.close() }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func label(_ text: String) -> NSTextField? { descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.stringValue == text } }
            func button(_ title: String) -> NSButton? { descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title } }
            func outline(containing path: String) -> NSOutlineView? {
                descendants(window.contentView!).compactMap { $0 as? NSOutlineView }.first { table in
                    (0..<table.numberOfRows).contains { (table.item(atRow: $0) as? ChangedFileNode)?.file?.path == path }
                }
            }
            func selectedPaths(_ table: NSOutlineView?) -> [String] {
                guard let table else { return [] }
                return table.selectedRowIndexes.compactMap { (table.item(atRow: $0) as? ChangedFileNode)?.file?.path }
            }
            func wait(_ label: String, _ condition: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(20)
                while !condition() {
                    #expect(ContinuousClock.now < deadline, Comment(rawValue: label))
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            try await wait("dialog loaded") { outline(containing: "a.txt") != nil && button("Commit")?.isEnabled == true }
            #expect(
                label("There are no staged changes")?.isHidden == false && label("There are no unstaged changes")?.isHidden == true,
                "staged list shows the upstream empty-state text")
            #expect(
                button("Unstage")?.isEnabled == true
                    && descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.toolTip == "Unstage all" }?.isEnabled == true
                    && button("Stash staged changes")?.isEnabled == true,
                "Unstage, Unstage All and Stash staged changes stay enabled with an empty index")
            let options = descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.menu?.items.first?.title == "Options" }
            options?.menu?.delegate?.menuNeedsUpdate?(options!.menu!)
            #expect(options != nil && !(options!.menu!.items.contains { $0.title == "Allow Empty" }), "no extra Allow Empty commit option")

            button("Commit")!.performClick(nil)
            try await wait("no-staged confirmation precedes empty-message validation") { window.attachedSheet != nil }
            #expect(label("Please enter a commit message.") == nil, "message validation not reached before the staging choice")
            window.endSheet(window.attachedSheet!, returnCode: .alertThirdButtonReturn)
            try await wait("dialog idle after cancel") { button("Commit")?.isEnabled == true }
            #expect(try fixture.git(["diff", "--cached", "--name-only"], in: repo).isEmpty, "cancel stages nothing")

            let unstagedTable = outline(containing: "a.txt")!
            let row = (0..<unstagedTable.numberOfRows).first { (unstagedTable.item(atRow: $0) as? ChangedFileNode)?.file?.path == "a.txt" }!
            unstagedTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            button("Stage")!.performClick(nil)
            try await wait("a.txt staged") {
                (try? fixture.git(["diff", "--cached", "--name-only"], in: repo)) == "a.txt" && outline(containing: "b.txt") !== outline(containing: "a.txt")
                    && button("Commit")?.isEnabled == true
            }
            #expect(
                selectedPaths(outline(containing: "b.txt")) == ["b.txt"] && selectedPaths(outline(containing: "a.txt")).isEmpty,
                "after staging, Unstaged advances to the next remaining file and Staged has no selection")
            #expect(CommitWorkflowDialog.nextItemToSelect(rows: ["a", "b", "c"], selected: ["c"]) == "a", "next item falls back to the first file")
        }

        @Test("Commit dialog selection filter and message") private static func commitDialogSelectionFilterAndMessage() async throws {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let repo = try fixture.repository("dialog")
            for name in ["A.cs", "b.txt", "C.CS"] { try "x\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            _ = try fixture.git(["add", "."], in: repo)
            _ = try fixture.git(["commit", "-q", "-m", "base"], in: repo)
            for name in ["A.cs", "b.txt", "C.CS"] { try "y\n".write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            let store = AppSettingsStore.shared
            let savedEditor = store.commitMessageEditorPreferences
            let savedCommit = store.commitPreferences
            defer {
                store.saveCommitMessageEditorPreferences(savedEditor)
                store.saveCommitPreferences(savedCommit)
            }
            var editor = savedEditor
            editor.showsSelectionFilter = false
            editor.markIllFormedLines = true
            editor.messageEditorWordWrap = false
            store.saveCommitMessageEditorPreferences(editor)
            var commitPreferences = savedCommit
            commitPreferences.validation = CommitValidationPreferences()
            commitPreferences.validation.maximumSubjectLength = 10
            commitPreferences.validation.maximumLineLength = 20
            commitPreferences.validation.autoWrap = false
            commitPreferences.validation.requireEmptySecondLine = false
            store.saveCommitPreferences(commitPreferences)

            let module = GitRepositoryModule(repositoryURL: repo)
            _ = try await module.loadRepositoryState()
            let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            owner.isReleasedWhenClosed = false
            defer { owner.close() }
            let controller = CommitWorkflowDialog.present(
                source: module, initialMode: .normal, head: nil, draft: nil, owner: owner,
                onRepositoryChanged: { _ in }, onClose: {})
            let window = controller.window!
            defer { window.close() }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let unstaged = descendants(window.contentView!).compactMap { $0 as? NSOutlineView }.first!
            func paths() -> [String] { (0..<unstaged.numberOfRows).compactMap { (unstaged.item(atRow: $0) as? ChangedFileNode)?.file?.path } }
            func selected() -> [String] { unstaged.selectedRowIndexes.compactMap { (unstaged.item(atRow: $0) as? ChangedFileNode)?.file?.path }.sorted() }
            let deadline = ContinuousClock.now + .seconds(20)
            while Set(paths()) != ["A.cs", "b.txt", "C.CS"] {
                #expect(ContinuousClock.now < deadline, "dialog lists unstaged files")
                try await Task.sleep(for: .milliseconds(20))
            }
            let filter = descendants(window.contentView!).compactMap { $0 as? NSComboBox }.first { $0.accessibilityIdentifier() == "CommitSelectionFilter" }!
            func barHidden() -> Bool { filter.superview?.isHidden ?? true }
            #expect(barHidden(), "selection filter hidden per CommitDialogSelectionFilter")
            let commandF = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
            #expect(window.contentView!.performKeyEquivalent(with: commandF), "Cmd+F handled")
            #expect(!barHidden(), "ToggleSelectionFilter shows the toolbar")
            #expect(!store.commitMessageEditorPreferences.showsSelectionFilter, "toggling does not change the persisted setting (upstream)")
            let initialSelection = selected()
            filter.stringValue = #"\.cs$"#
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: filter)
            #expect(selected() == initialSelection, "selection waits for the throttle")
            let selectDeadline = ContinuousClock.now + .seconds(5)
            while selected() != ["A.cs", "C.CS"] {
                #expect(ContinuousClock.now < selectDeadline, "regex selects matching unstaged files: \(selected())")
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(filter.objectValues.compactMap { $0 as? String } == [#"\.cs$"#], "matching filter added to history")
            filter.stringValue = "("
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: filter)
            try await Task.sleep(for: .milliseconds(400))
            #expect(filter.toolTip?.hasPrefix("Error ") == true && selected() == ["A.cs", "C.CS"], "invalid regex reported, selection kept")
            filter.stringValue = "nomatch"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: filter)
            try await Task.sleep(for: .milliseconds(400))
            #expect(
                selected().isEmpty && filter.objectValues.count == 1 && filter.toolTip == CommitSelectionFilter.toolTip,
                "no match clears selection without history")
            #expect(window.contentView!.performKeyEquivalent(with: commandF) && barHidden(), "ToggleSelectionFilter hides the toolbar")

            let message = descendants(window.contentView!).compactMap { $0 as? CommitMessageTextView }.first!
            message.string = "0123456789AB\nx\n" + String(repeating: "z", count: 25)
            #expect(
                message.overLimitRanges == [NSRange(location: 10, length: 2), NSRange(location: 15 + 20, length: 5)],
                "live over-limit ranges: \(message.overLimitRanges)")
            #expect(message.illFormedRanges == [NSRange(location: 13, length: 1)], "ill-formed line 2 marked: \(message.illFormedRanges)")
            message.setSelectedRange(NSRange(location: message.string.utf16.count, length: 0))
            message.insertText("zz", replacementRange: message.selectedRange())
            #expect(message.overLimitRanges.last == NSRange(location: 35, length: 7), "colouring updates while typing")
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = message.delegate!.textView!(message, menu: NSMenu(), for: event, at: 0)!
            #expect(
                Array(menu.items.prefix(6)).map(\.title) == ["Cut", "Copy", "Paste", "Delete", "Select all", "Word wrap (except subject line)"],
                "source edit actions precede dictionary/preferences/native services")
            let delete = menu.items.first { $0.title == "Delete" }!
            let originalMessage = message.string
            message.setSelectedRange(NSRange(location: 2, length: 3))
            NSApp.sendAction(delete.action!, to: delete.target, from: delete)
            #expect(
                message.string == (originalMessage as NSString).replacingCharacters(in: NSRange(location: 2, length: 3), with: ""),
                "Delete changes only selected text through native editing")
            let afterDeletion = message.string
            message.setSelectedRange(NSRange(location: 2, length: 0))
            NSApp.sendAction(delete.action!, to: delete.target, from: delete)
            #expect(message.string == afterDeletion, "Delete without selection is a source-equivalent no-op")
            let selectAll = menu.items.first { $0.title == "Select all" }!
            NSApp.sendAction(selectAll.action!, to: selectAll.target, from: selectAll)
            #expect(message.selectedRange() == NSRange(location: 0, length: message.string.utf16.count), "native Select all action selects the entire message")
            let wrap = menu.items.first { $0.title == "Word wrap (except subject line)" }
            let mark = menu.items.first { $0.title == "Mark ill formed lines" }
            #expect(wrap != nil && mark?.state == .on, "context menu offers word wrap and the ill-formed toggle")
            message.string = "subject stays long enough to exceed\none two three four five six seven"
            menu.performActionForItem(at: menu.index(of: wrap!))
            #expect(
                message.string == "subject stays long enough to exceed\none two three four\nfive six seven",
                "body wrapped at the configured limit: \(message.string)")
            menu.performActionForItem(at: menu.index(of: mark!))
            #expect(!store.commitMessageEditorPreferences.markIllFormedLines && message.illFormedRanges.isEmpty, "toggle off persists and clears marks")
            let menuAgain = message.delegate!.textView!(message, menu: NSMenu(), for: event, at: 0)!
            let markAgain = menuAgain.items.first { $0.title == "Mark ill formed lines" }!
            #expect(markAgain.state == .off, "toggle reflects persisted state")
            menuAgain.performActionForItem(at: menuAgain.index(of: markAgain))
            #expect(store.commitMessageEditorPreferences.markIllFormedLines, "toggle on persists")

            let templates = descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.first == "Commit templates" }!
            let conventional = templates.menu!.items.first { $0.title == "Conventional Commits" }!.submenu!
            message.string = "fix: keep this subject\n\nbody"
            message.setSelectedRange(NSRange(location: 0, length: 0))
            conventional.performActionForItem(at: conventional.index(of: conventional.items.first { $0.title == "feat" }!))
            #expect(message.string == "feat: keep this subject\n\nbody" && message.selectedRange().location == 6, "menu replaces the type: \(message.string)")
            conventional.performActionForItem(at: conventional.index(of: conventional.items.first { $0.title == "Reviewed-by" }!))
            #expect(
                message.string == "feat: keep this subject\n\nbody\nReviewed-by: " && message.selectedRange().location == message.string.utf16.count,
                "footer appended on a new line with caret at the end")

            let status = descendants(window.contentView!).compactMap { $0 as? CommitAuthorStatusButton }.first!
            #expect(
                status.statusText.hasPrefix("Committer Commit Parity <parity@example.com>") && status.toolTip == CommitAuthorStatus.toolTip,
                "author status shows the committer: \(status.statusText)")
            let options = descendants(window.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.first == "Options" }!
            func optionItem(_ prefix: String) -> NSMenuItem? { options.menu!.items.first { $0.title.hasPrefix(prefix) } }
            options.menu!.performActionForItem(at: options.menu!.index(of: optionItem("Override author")!))
            let alertDeadline = ContinuousClock.now + .seconds(5)
            while window.attachedSheet == nil {
                #expect(ContinuousClock.now < alertDeadline, "author override prompt shown")
                try await Task.sleep(for: .milliseconds(20))
            }
            let alertWindow = window.attachedSheet!
            descendants(alertWindow.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!.stringValue = "Other <other@example.com>"
            descendants(alertWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Use Author" }!.performClick(nil)
            let overrideDeadline = ContinuousClock.now + .seconds(5)
            while !status.statusText.hasSuffix(" Author Other <other@example.com>") {
                #expect(ContinuousClock.now < overrideDeadline, "author override shown: \(status.statusText)")
                try await Task.sleep(for: .milliseconds(20))
            }
            while window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
            status.performClick(nil)
            let settingsDeadline = ContinuousClock.now + .seconds(5)
            while window.attachedSheet == nil {
                #expect(ContinuousClock.now < settingsDeadline, "author status opens Settings")
                try await Task.sleep(for: .milliseconds(20))
            }
            let settings = window.attachedSheet!.contentViewController as? SettingsViewController
            #expect(settings?.currentCategoryID == "git_config", "Settings opened at Git ▸ Config")
            window.endSheet(window.attachedSheet!)
            try await Task.sleep(for: .milliseconds(100))
        }

        private final class Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitExtensionsMac-CommitParity-\(UUID().uuidString)", isDirectory: true)

            init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            func remove() { try? FileManager.default.removeItem(at: root) }

            func repository(_ name: String) throws -> URL {
                let url = root.appendingPathComponent(name, isDirectory: true)
                _ = try git(["init", "-q", "-b", "main", url.path], in: root)
                _ = try git(["config", "user.name", "Commit Parity"], in: url)
                _ = try git(["config", "user.email", "parity@example.com"], in: url)
                _ = try git(["config", "commit.gpgsign", "false"], in: url)
                return url
            }

            func superprojectWithSubmodule() throws -> (superproject: URL, submodule: URL) {
                let child = try repository("child")
                try "child\n".write(to: child.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
                _ = try git(["add", "."], in: child)
                _ = try git(["commit", "-q", "-m", "child"], in: child)
                let superproject = try repository("super")
                try "super\n".write(to: superproject.appendingPathComponent("super.txt"), atomically: true, encoding: .utf8)
                _ = try git(["add", "."], in: superproject)
                _ = try git(["commit", "-q", "-m", "super"], in: superproject)
                _ = try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", "../child", "sub"], in: superproject)
                _ = try git(["commit", "-q", "-m", "add sub"], in: superproject)
                let submodule = superproject.appendingPathComponent("sub", isDirectory: true)
                _ = try git(["config", "user.name", "Commit Parity"], in: submodule)
                _ = try git(["config", "user.email", "parity@example.com"], in: submodule)
                _ = try git(["config", "commit.gpgsign", "false"], in: submodule)
                _ = try git(["checkout", "-q", "-B", "main"], in: submodule)
                return (superproject, submodule)
            }

            @discardableResult
            func git(_ arguments: [String], in directory: URL) throws -> String {
                let process = FixtureProcess()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.standardOutput = output
                process.standardError = errors
                var environment = ProcessInfo.processInfo.environment
                environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                environment["GIT_CONFIG_NOSYSTEM"] = "1"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                process.environment = environment
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw Failure(errorDescription: "git \(arguments.joined(separator: " ")) failed: \(String(decoding: errorData, as: UTF8.self))")
                }
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

typealias CommitDialogTests = UIIntegrationTests.CommitDialogTests
