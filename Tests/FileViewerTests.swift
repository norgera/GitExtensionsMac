@testable import GitExtensionsCore
@testable import GitCommands
@testable import GitUI
import Foundation

enum FileViewerTests {
    static func run() {
        testDiffArguments()
        testEncodingAndBinaryPresentation()
        testSyntaxDetection()
        try! testDifftoolCommands()
        testInlinePresentation()
        print("FileViewerTests: passed")
    }

    private static func testDiffArguments() {
        expect(FileDiffOptions().gitArguments.isEmpty, "default diff options preserve the normal Git arguments")
        expect(
            FileDiffOptions(whitespace: .endOfLine, contextLines: 5, treatsAllFilesAsText: true).gitArguments
                == ["--ignore-space-at-eol", "--unified=5", "--text"],
            "diff options preserve intentional argument ordering"
        )
        expect(
            FileDiffOptions(whitespace: .all, showsEntireFile: true).gitArguments
                == ["--ignore-all-space", "--inter-hunk-context=9000", "--unified=9000"],
            "entire-file mode uses the upstream inter-hunk and unified arguments"
        )
    }

    private static func testEncodingAndBinaryPresentation() {
        let bom = FileContentDecoder.decode(Data([0xEF, 0xBB, 0xBF] + Array("héllo".utf8)), path: "note.txt", requestedEncoding: .automatic)
        expect(bom.kind == .text && bom.text == "héllo" && bom.encoding == .utf8, "UTF-8 BOM is detected and removed")

        let utf16 = Data([0xFF, 0xFE, 0x68, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x6C, 0x00, 0x6F, 0x00])
        let utf16Content = FileContentDecoder.decode(utf16, path: "note.txt", requestedEncoding: .automatic)
        expect(utf16Content.text == "hello" && utf16Content.encoding == .utf16LittleEndian, "UTF-16 BOM is detected")

        let binary = FileContentDecoder.decode(Data([0x00, 0x01, 0x41]), path: "sample.bin", requestedEncoding: .automatic)
        expect(binary.kind == .binary && binary.text.contains("00000000"), "binary content uses a stable hex presentation")

        let png = FileContentDecoder.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]), path: "image.png", requestedEncoding: .automatic)
        expect(png.kind == .image, "known image content remains image data")
    }

    private static func testSyntaxDetection() {
        expect(FileViewerSyntaxDetector.language(for: "Sources/App.swift") == .swift, "Swift extension detection")
        expect(FileViewerSyntaxDetector.language(for: "Dockerfile") == .scripting, "filename-based detection")
        expect(FileViewerSyntaxDetector.language(for: "config.yaml") == .data, "data-language detection")
        expect(FileViewerSyntaxDetector.language(for: "LICENSE") == .plainText, "unknown names use plain text")
    }

    private static func testDifftoolCommands() throws {
        let parent = testObjectID("parent")
        let object = testObjectID("object")
        let commit = makeCommit(object, parents: [parent])
        let renamed = ChangedFile(id: "new.swift", path: "new.swift", oldPath: "old.swift", changeType: .renamed, additions: 1, deletions: 1)
        let command = try FileViewerCommandBuilder.difftool(commit: commit, file: renamed)
        expect(
            command.arguments == ["difftool", "--no-prompt", parent.string, object.string, "--", "old.swift", "new.swift"],
            "revision difftool keeps revisions and rename paths separate and ordered"
        )
        expect(!command.accessesRemote && !command.changesRepositoryState, "difftool is a local read/presentation command")
        let custom = try FileViewerCommandBuilder.difftool(commit: commit, file: renamed, customToolPath: "/Applications/Diff Tool.app/Contents/MacOS/diff")
        expect(
            custom.arguments[2] == "--extcmd=/Applications/Diff Tool.app/Contents/MacOS/diff",
            "custom macOS difftool paths remain one argument"
        )

        let artificial = makeCommit(object, kind: .workingDirectory)
        let artificialCommand = try FileViewerCommandBuilder.difftool(commit: artificial, file: renamed)
        expect(
            artificialCommand.arguments
                == ["difftool", "--no-prompt", "--", "old.swift", "new.swift"],
            "working-directory rows do not masquerade as object IDs"
        )
    }

    private static func testInlinePresentation() {
        let lines = [
            DiffLine(id: "d", oldLineNumber: 1, newLineNumber: nil, kind: .deletion, text: "let old = 1"),
            DiffLine(id: "a", oldLineNumber: nil, newLineNumber: 1, kind: .addition, text: "let new = 1")
        ]
        let presentation = DiffLinePresentation.build(from: lines)
        expect(presentation.count == 2 && presentation.allSatisfy { $0.inlineChange != nil }, "paired lines retain word-level changed ranges")
        expect(DiffGutterMetrics(lines: lines).numberColumnWidth >= 1, "gutter metrics cover both line-number columns")
    }

    private static func makeCommit(_ object: ObjectID, parents: [ObjectID] = [], kind: Commit.Kind = .revision) -> Commit {
        Commit(
            id: kind == .workingDirectory ? .workingDirectory : .object(object),
            shortID: object.shortString,
            subject: "Test",
            body: "",
            authorName: "Test",
            authorEmail: "test@example.com",
            authorDate: Date(timeIntervalSince1970: 1),
            committerName: "Test",
            committerEmail: "test@example.com",
            commitDate: Date(timeIntervalSince1970: 1),
            parentIDs: parents,
            references: [],
            kind: kind
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
