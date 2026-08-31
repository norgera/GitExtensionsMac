import GitExtensionsCore
import Foundation

package enum FileContentDecoder {
    package static func decode(
        _ data: Data,
        path: String,
        requestedEncoding: RepositoryTextEncoding
    ) -> RepositoryFileContent {
        if isImage(data, path: path) {
            return RepositoryFileContent(path: path, kind: .image, data: data)
        }

        if requestedEncoding == .automatic, !hasTextPreamble(data), isBinary(data) {
            return RepositoryFileContent(
                path: path,
                kind: .binary,
                text: hexDump(data),
                data: data
            )
        }

        let candidates = encodings(for: data, requested: requestedEncoding)
        for candidate in candidates {
            if let value = String(data: dataWithoutPreamble(data, encoding: candidate), encoding: foundationEncoding(candidate)) {
                return RepositoryFileContent(
                    path: path,
                    kind: .text,
                    text: value,
                    data: data,
                    encoding: candidate
                )
            }
        }

        return RepositoryFileContent(
            path: path,
            kind: .binary,
            text: hexDump(data),
            data: data
        )
    }

    private static func encodings(
        for data: Data,
        requested: RepositoryTextEncoding
    ) -> [RepositoryTextEncoding] {
        guard requested == .automatic else { return [requested] }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return [.utf8] }
        if data.starts(with: [0xFF, 0xFE]) { return [.utf16LittleEndian] }
        if data.starts(with: [0xFE, 0xFF]) { return [.utf16BigEndian] }
        return [.utf8, .westernISO88591]
    }

    private static func hasTextPreamble(_ data: Data) -> Bool {
        data.starts(with: [0xEF, 0xBB, 0xBF])
            || data.starts(with: [0xFF, 0xFE])
            || data.starts(with: [0xFE, 0xFF])
    }

    private static func dataWithoutPreamble(
        _ data: Data,
        encoding: RepositoryTextEncoding
    ) -> Data {
        let count: Int
        switch encoding {
        case .utf8 where data.starts(with: [0xEF, 0xBB, 0xBF]): count = 3
        case .utf16LittleEndian where data.starts(with: [0xFF, 0xFE]): count = 2
        case .utf16BigEndian where data.starts(with: [0xFE, 0xFF]): count = 2
        default: count = 0
        }
        return count == 0 ? data : data.dropFirst(count)
    }

    private static func foundationEncoding(_ encoding: RepositoryTextEncoding) -> String.Encoding {
        switch encoding {
        case .automatic, .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .westernISO88591: .isoLatin1
        case .windows1252: .windowsCP1252
        }
    }

    private static func isImage(_ data: Data, path: String) -> Bool {
        let lower = path.lowercased()
        let supportedExtension = [".png", ".jpg", ".jpeg", ".gif", ".tif", ".tiff", ".bmp", ".ico", ".webp"]
            .contains { lower.hasSuffix($0) }
        guard supportedExtension else { return false }
        return data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || data.starts(with: [0xFF, 0xD8, 0xFF])
            || data.starts(with: Array("GIF8".utf8))
            || data.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
            || data.starts(with: Array("BM".utf8))
            || data.starts(with: [0x00, 0x00, 0x01, 0x00])
            || (data.count >= 12 && data[0..<4] == Data("RIFF".utf8) && data[8..<12] == Data("WEBP".utf8))
    }

    private static func isBinary(_ data: Data) -> Bool {
        if data.contains(0) { return true }
        guard !data.isEmpty else { return false }
        let sample = data.prefix(8_192)
        let controls = sample.reduce(into: 0) { count, byte in
            if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { count += 1 }
        }
        return Double(controls) / Double(sample.count) > 0.10
    }

    private static func hexDump(_ data: Data) -> String {
        var lines = ["Binary file (\(data.count) bytes)", ""]
        for offset in stride(from: 0, to: data.count, by: 16) {
            let bytes = data[offset..<min(offset + 16, data.count)]
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            let padded = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." }.map(String.init).joined()
            lines.append(String(format: "%08x  %@  |%@|", offset, padded, ascii))
        }
        return lines.joined(separator: "\n")
    }
}

package enum FileViewerCommandBuilder {
    package static func difftool(commit: Commit, file: ChangedFile, customToolPath: String? = nil) throws -> GitCommand {
        let paths = [file.oldPath, file.path].compactMap { $0 }
        let customTool = customToolPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customArguments = customTool.flatMap { $0.isEmpty ? nil : ["--extcmd=\($0)"] } ?? []
        let prefix = ["difftool", "--no-prompt"] + customArguments
        let arguments: [String]
        switch commit.kind {
        case .revision:
            guard let objectID = commit.objectID else { throw RepositoryDataSourceError.unavailable }
            if let parent = commit.parentIDs.first {
                arguments = prefix + [parent.string, objectID.string, "--"] + paths
            } else {
                arguments = prefix + ["--root", objectID.string, "--"] + paths
            }
        case .index:
            arguments = prefix + ["--cached", "--"] + paths
        case .workingDirectory:
            arguments = prefix + ["--"] + paths
        }
        return GitCommand(arguments: arguments, accessesRemote: false, changesRepositoryState: false)
    }
}
