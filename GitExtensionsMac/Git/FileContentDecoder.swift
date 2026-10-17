import GitExtensionsCore
import Foundation

package enum FileContentDecoder {
    package static func decode(
        _ data: Data,
        path: String,
        requestedEncoding: RepositoryTextEncoding,
        configuredEncoding: RepositoryTextEncoding? = nil
    ) -> RepositoryFileContent {
        if isImage(data, path: path) {
            return RepositoryFileContent(path: path, kind: .image, data: data)
        }

        if requestedEncoding == .automatic, !hasTextPreamble(data), isBinary(data) {
            return RepositoryFileContent(
                path: path,
                kind: .binary,
                text: hexDump(data, path: path),
                data: data
            )
        }

        if let decoded = decodedText(data, requestedEncoding: requestedEncoding, configuredEncoding: configuredEncoding) {
            return RepositoryFileContent(path: path, kind: .text, text: decoded.text, data: data, encoding: decoded.encoding)
        }

        return RepositoryFileContent(path: path, kind: .binary, text: hexDump(data, path: path), data: data)
    }

    package static func decodedText(_ data: Data, requestedEncoding: RepositoryTextEncoding,
                                    configuredEncoding: RepositoryTextEncoding? = nil) -> (text: String, encoding: RepositoryTextEncoding, preambleCodeUnits: Int)? {
        let requestedEncoding = requestedEncoding == .automatic && !hasTextPreamble(data)
            ? (configuredEncoding ?? requestedEncoding) : requestedEncoding
        let candidates = encodings(for: data, requested: requestedEncoding)
        for candidate in candidates {
            if let value = String(data: dataWithoutPreamble(data, encoding: candidate), encoding: foundationEncoding(candidate)) {
                return (value, candidate, preambleByteCount(data, encoding: candidate) > 0 ? 1 : 0)
            }
        }

        return nil
    }

    private static let previewAnsiCodes = try! NSRegularExpression(pattern: #"\x1b[\x40-\x5f][^\n]*?[\x40-\x7e]"#)
    package static func previewText(_ text: String, path: String, historical: Bool) -> String {
        guard historical, !path.lowercased().hasSuffix(".diff"), !path.lowercased().hasSuffix(".patch") else { return text }
        return previewAnsiCodes.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: "")
    }

    private static func encodings(
        for data: Data,
        requested: RepositoryTextEncoding
    ) -> [RepositoryTextEncoding] {
        guard requested == .automatic else { return [requested] }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return [RepositoryTextEncoding(ianaName: "utf-32le")!] }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return [RepositoryTextEncoding(ianaName: "utf-32be")!] }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return [.utf8] }
        if data.starts(with: [0xFF, 0xFE]) { return [.utf16LittleEndian] }
        if data.starts(with: [0xFE, 0xFF]) { return [.utf16BigEndian] }
        return [.utf8, .westernISO88591]
    }

    private static func hasTextPreamble(_ data: Data) -> Bool {
        data.starts(with: [0xEF, 0xBB, 0xBF])
            || data.starts(with: [0x00, 0x00, 0xFE, 0xFF])
            || data.starts(with: [0xFF, 0xFE])
            || data.starts(with: [0xFE, 0xFF])
    }

    private static func dataWithoutPreamble(
        _ data: Data,
        encoding: RepositoryTextEncoding
    ) -> Data {
        let count = preambleByteCount(data, encoding: encoding)
        return count == 0 ? data : data.dropFirst(count)
    }

    private static func preambleByteCount(_ data: Data, encoding: RepositoryTextEncoding) -> Int {
        let count: Int
        switch encoding {
        case _ where encoding.ianaName == "utf-32le" && data.starts(with: [0xFF, 0xFE, 0x00, 0x00]): count = 4
        case _ where encoding.ianaName == "utf-32be" && data.starts(with: [0x00, 0x00, 0xFE, 0xFF]): count = 4
        case .utf8 where data.starts(with: [0xEF, 0xBB, 0xBF]): count = 3
        case .utf16LittleEndian where data.starts(with: [0xFF, 0xFE]): count = 2
        case .utf16BigEndian where data.starts(with: [0xFE, 0xFF]): count = 2
        default: count = 0
        }
        return count
    }

    private static func foundationEncoding(_ encoding: RepositoryTextEncoding) -> String.Encoding {
        encoding.foundationEncoding
    }

    package static func hasImageExtension(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".png", ".jpg", ".jpeg", ".gif", ".tif", ".tiff", ".bmp", ".ico", ".webp"].contains { lower.hasSuffix($0) }
    }

    private static func isImage(_ data: Data, path: String) -> Bool {
        guard hasImageExtension(path) else { return false }
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

    package static func hexDump(_ data: Data, path: String) -> String {
        guard !data.isEmpty else { return "" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let size = formatter.string(from: NSNumber(value: data.count)) ?? String(data.count)
        let mb = Double(data.count) / 1_048_576
        formatter.minimumFractionDigits = 1; formatter.maximumFractionDigits = 1
        let megabytes = mb >= 0.1 ? (formatter.string(from: NSNumber(value: mb)) ?? String(format: "%.1f", mb)) + " MB / " : ""
        var text = "Binary file: \(path)\n\n\(megabytes)\(size) bytes:\n\n"
        let bytes = Array(data.prefix(4096))
        var rows: [String] = []
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            func byte(_ index: Int) -> UInt8? { index < bytes.count ? bytes[index] : nil }
            let hex = (0..<2).map { column in
                (0..<8).map { byte(offset + column * 8 + $0).map { String(format: "%02X", $0) } ?? "  " }.joined(separator: " ")
            }.joined(separator: "  ")
            let characters = (0..<2).map { column in
                (0..<8).map { index -> String in
                    guard let value = byte(offset + column * 8 + index) else { return " " }
                    return value < 32 || (127...159).contains(value) ? "." : String(UnicodeScalar(value))
                }.joined()
            }.joined(separator: " ")
            rows.append(String(format: "%04X   ", offset) + hex + "   " + characters)
        }
        text += rows.joined(separator: "\n")
        if data.count > 4096 { text += "\n[Truncated]" }
        return text
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
