import GitCommands
import Foundation

struct PushButtonPresentation: Equatable {
    let text: String
    let imageName: String
    let tooltip: String?

    init(data: AheadBehindData?, enabled: Bool, shortcut: String = "") {
        let suffix = shortcut.isEmpty ? "" : " (\(shortcut))"
        guard enabled, let data else {
            text = ""; imageName = "Push"; tooltip = "Push" + suffix
            return
        }
        text = data.display()
        imageName = data.behindCount.isEmpty ? "Push" : "Unstage"
        var lines: [String] = []
        if !data.aheadCount.isEmpty { lines.append("\(data.aheadCount) new commit(s) will be pushed") }
        if !data.behindCount.isEmpty { lines.append("\(data.behindCount) commit(s) should be integrated (or will be lost if force pushed)") }
        tooltip = lines.isEmpty ? nil : lines.joined(separator: "\n") + suffix
    }
}
