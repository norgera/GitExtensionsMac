import AppKit
import Foundation
import Testing

@testable import GitCommands
@testable import GitExtensionsCore
@testable import GitUI

extension UIIntegrationTests {
    @MainActor
    @Suite("Appearance")
    enum AppearanceTests {

        @Test("Contrast") static func contrast() {
            let vectors: [(Int, Float, AvatarContrastColor)] = [
                (0x000000, 0.5, .white), (0x757575, 0.5, .white), (0x999999, 1, .white),
                (0xFFFFFF, 0.5, .black), (0x999999, 0.5, .black), (0x777777, 0.4, .black),
                (0x708090, 0.5, .black), (0xFF4500, 0.5, .black), (0x6B8E23, 0.5, .black),
                (0x777777, 0.5, .white), (0x787878, 0.5, .black),
                (0x0A0A0A, 0.5, .white), (0x0B0B0B, 0.5, .white), (0x404040, 0.5, .white),
                (0x808080, 0.5, .black), (0xC0C0C0, 0.5, .black),
                (0xFF0000, 0.5, .black), (0x00FF00, 0.5, .black), (0x0000FF, 0.5, .white),
                (0xFFFFFF, 5.5, .white), (0x000000, 0, .white), (0x000000, -0.01, .black),
            ]
            for (rgb, threshold, expected) in vectors {
                #expect(
                    AvatarContrast.foreground(
                        red: UInt8((rgb >> 16) & 255), green: UInt8((rgb >> 8) & 255),
                        blue: UInt8(rgb & 255), threshold: threshold) == expected, "contrast \(String(rgb, radix: 16)) at \(threshold)")
            }
            #expect(abs(AvatarContrast.linearize(10) - 10.0 / 255 / 12.92) < 1e-15, "linear branch at channel 10")
            #expect(abs(AvatarContrast.linearize(11) - pow((11.0 / 255 + 0.055) / 1.055, 2.4)) < 1e-15, "power branch at channel 11")
            #expect(abs(AvatarContrast.luminance(red: 112, green: 128, blue: 144) - 0.20896704076536146) < 1e-12, "SlateGray relative luminance")
            let equality: Float = 1 / (Float(0.185) * 2)
            #expect(equality * (Float(0.185) * 2) == 1, "exact Float cutoff fixture")
            #expect(AvatarContrast.foreground(red: 255, green: 255, blue: 255, threshold: equality) == .white, "equal luminance chooses white")
            #expect(AvatarContrast.foreground(red: 255, green: 255, blue: 255, threshold: equality.nextDown) == .black, "strictly above cutoff chooses black")
            for alpha in [0.0, 0.2, 1.0] {
                let background = NSColor(srgbRed: 112.0 / 255, green: 128.0 / 255, blue: 144.0 / 255, alpha: alpha)
                #expect(AvatarContrast.foreground(background: background, threshold: 0.5) == NSColor.black, "alpha ignored, foreground opaque")
            }
            #expect(AvatarPreferences().initialsPalette == "SlateGray,RoyalBlue,Purple,OrangeRed,Teal,OliveDrab", "palette unchanged")
            #expect(AvatarPreferences().luminanceThreshold == 0.5, "threshold unchanged")
        }

        static var sourceThemes: URL {
            TestResources.themes
        }

        @Test("Light app colors built while a dark appearance is current") static func lightAppOnDarkSystem() throws {
            let dark = try #require(NSAppearance(named: .darkAqua))
            let light = try #require(NSAppearance(named: .aqua))
            func lightness(_ color: NSColor) -> CGFloat {
                var value: CGFloat = 0
                light.performAsCurrentDrawingAppearance {
                    let rgb = color.usingColorSpace(.sRGB) ?? .black
                    value = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                }
                return value
            }
            let grid = RevisionGridViewController()
            let window = NSWindow(contentViewController: grid)
            window.appearance = light
            window.isReleasedWhenClosed = false
            defer { window.close() }
            var rows: [NSColor] = []
            var dimmed: NSColor = .clear
            var blended: NSColor = .clear
            dark.performAsCurrentDrawingAppearance {
                rows = (0..<2).compactMap { (grid.tableView(NSTableView(), rowViewForRow: $0) as? GitExtensionsSelectionRowView)?.repositoryBackgroundColor }
                dimmed = DiffTextColors.color(.palette(2, dim: true), foreground: true)
                blended = ApplicationColors.blended(.systemRed, fraction: 0.75, of: .textBackgroundColor)
            }
            #expect(rows.count == 2 && rows.allSatisfy { lightness($0) > 0.9 }, "grid rows and alternate rows stay light in a light window")
            #expect(lightness(blended) > 0.7, "blended emphasis resolves against the light editor background")
            #expect(lightness(dimmed) > 0.45, "dimmed diff colors resolve against the light editor background")
        }

        @Test("Themes") static func themes() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Appearance-Themes-" + UUID().uuidString)
            let bundled = root.appendingPathComponent("bundled")
            let user = root.appendingPathComponent("user")
            try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for name in ["invariant.css", "dark.css", "dark+.css", "light+.css"] {
                try FileManager.default.copyItem(at: sourceThemes.appendingPathComponent(name), to: bundled.appendingPathComponent(name))
                _ = try ApplicationThemeReader.load(name, colorblind: false, bundled: bundled, user: user)
                _ = try ApplicationThemeReader.load(name, colorblind: true, bundled: bundled, user: user)
            }
            let defaults = try ApplicationThemeReader.load("invariant.css", colorblind: false, bundled: bundled, user: user)
            #expect(
                ApplicationThemeReader.applicationColorNames.count == 53 && ApplicationThemeReader.applicationColorNames.allSatisfy { defaults[$0] != nil },
                "53 invariant application colors retained")
            #expect(defaults["GraphBranch8"] == -1 && defaults["RemoteBranch"] == 0x8B0009, "bundled defaults unchanged")
            #expect(
                ApplicationThemeReader.resolve("bright.css", bundled: bundled, user: user) == bundled.appendingPathComponent("bright.css"),
                "upstream builtin URL vector")
            #expect(
                ApplicationThemeReader.resolve("{UserAppData}/bright_custom.css", bundled: bundled, user: user)
                    == user.appendingPathComponent("bright_custom.css"), "upstream macro URL vector")
            #expect(
                ApplicationThemeReader.resolve("bright.CSS", bundled: bundled, user: user) == bundled.appendingPathComponent("bright.css"),
                "extension case insensitive")
            #expect(
                ApplicationThemeReader.resolve("light", bundled: bundled, user: user) == bundled.appendingPathComponent("invariant.css"),
                "default theme identity")
            for (value, expected) in [(0xFF0000, "#ff0000"), (0x00FF00, "#00ff00"), (0x0000FF, "#0000ff"), (0xAB12_3456, "#123456"), (-1, "#000000")] {
                #expect(ApplicationThemeReader.formatColor(value) == expected, "ThemePersistence RGB format")
            }
            func write(_ text: String, name: String = "fixture.css") throws {
                try text.write(to: user.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            func load(_ text: String, colorblind: Bool = false) throws -> [String: Int] {
                try write(text)
                return try ApplicationThemeReader.load("user/fixture.css", colorblind: colorblind, bundled: bundled, user: user)
            }
            func rejects(_ text: String, containing: String? = nil, colorblind: Bool = false) throws {
                try write(text)
                do {
                    _ = try ApplicationThemeReader.load("user/fixture.css", colorblind: colorblind, bundled: bundled, user: user)
                    Issue.record("Appearance: accepted invalid CSS \(text)")
                } catch {
                    if let containing { #expect(error.localizedDescription.contains(containing), "error identifies \(containing)") }
                }
            }
            for key in ApplicationThemeReader.systemColorNames + ApplicationThemeReader.applicationColorNames {
                for (value, expected) in [("#ff0000", 0xFF0000), ("#008000", 0x008000)] {
                    #expect(try load(".\(key) { color: \(value); }")[key] == expected, "upstream all-color vector \(key)")
                }
                let css = ".\(key).colorblind { color: blue; } .\(key) { color: red; }"
                #expect(try load(css)[key] == 0xFF0000, "normal variant \(key)")
                #expect(try load(css, colorblind: true)[key] == 0x0000FF, "specific variation overrides later normal \(key)")
            }
            #expect(try load("/* line */ .Control { COLOR: Green; } /* trailing */")["Control"] == 0x008000, "comments, whitespace, property/value casing")
            for (value, expected) in [
                ("#abc", 0xAABBCC), ("LightGoldenRodYellow", 0xFAFAD2), ("rebeccapurple", 0x663399),
                ("RGB(12,34,56)", 0x0C2238), ("rgb(100%,0%,50%)", 0xFF007F), ("rgb(10%,20%,30%)", 0x19324C),
                ("rgb(1,2%,3)", 0x010503), ("rgb(101%,0%,0%)", 0x010000), ("rgb(256,0,0)", 0xFF0000), ("WindowText", 0), ("ButtonText", 0),
                ("ThreeDDarkShadow", 0x666666),
            ] {
                #expect(try load(".Control { color: \(value); }")["Control"] == expected, "pinned accepted color \(value)")
            }
            try rejects(".InvalidColorName { color:red; }", containing: "InvalidColorName")
            try rejects(".control { color:red; }", containing: "control")
            for value in [
                "not-a-color", "#-12345", "#zzzzzz", "#1234", "#12345678", "rgb(12,bad,34,56)", "rgb(12,,34)", "rgb(-1,0,0)", "hsl(120,100%,50%)",
                "rgba(1,2,3,1)", "transparent", "inherit", "var(--red)", "var(--red, red)", "url(red)", "",
            ] {
                try rejects(".Control { color: \(value); }", containing: "Control")
            }
            try rejects(".Control {background:red;}")
            try rejects(".Control.colorblind { color:invalid; }", colorblind: false)
            #expect(try load(".Graph { color:red; }").isEmpty, "removed Graph migration ignored")
            #expect(try load(".Unknown.other { color:red; }").isEmpty, "disallowed variation ignores unknown key")
            #expect(try load(".GraphBranch8 { }")["GraphBranch8"] == -1, "empty graph slot supported")
            #expect(try load(".GraphBranch8 { color:invalid; }")["GraphBranch8"] == -1, "source empty parsed graph color semantics")
            #expect(try load(".Control { color:red; } }")["Control"] == 0xFF0000, "upstream ignored syntax-error test: extra brace tolerated")
            #expect(try load(".Control { color:red")["Control"] == 0xFF0000, "ExCSS EOF closes valid rule")
            #expect(try load(".Control { color:red; color:invalid; }")["Control"] == 0xFF0000, "invalid later declaration does not erase valid CSS property")
            #expect(try load(".Control { color:red !important; color:blue; }")["Control"] == 0xFF0000, "important declaration retained")
            try write(".Control {color:LightCoral;}", name: "base.css")
            #expect(try load("@import url(\"{UserAppData}/base.css\");")["Control"] == 0xF08080, "upstream import vector")
            #expect(try load("@import \"{UserAppData}/base.css\"; .Control {color:LightGreen;}")["Control"] == 0x90EE90, "local overrides imported color")
            try write("@import url(\"{UserAppData}/fixture.css\");", name: "base.css")
            try rejects("@import url(\"{UserAppData}/base.css\");", containing: "Cycling CSS import")
            try rejects("@import url(\"{UserAppData}/missing.css\");", containing: "fixture.css")
            try write(String(repeating: " ", count: 1_048_577), name: "oversized.css")
            do {
                _ = try ApplicationThemeReader.load("user/oversized.css", colorblind: false, bundled: bundled, user: user)
                Issue.record("Appearance oversized theme accepted")
            } catch { #expect(error.localizedDescription.contains("1,048,576"), "file reader limit") }
            try recovery(bundled: bundled, user: user)
        }

        static func recovery(bundled: URL, user: URL) throws {
            let domain = "Appearance-ThemePreferences-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            var failures: [ApplicationThemeFailure] = []
            func make() -> AppSettingsStore {
                AppSettingsStore(defaults: defaults, bundledThemes: bundled, userThemes: user, themeFailureReporter: { failures.append($0) })
            }
            let store = make()
            let theme = user.appendingPathComponent("custom.css")
            try ".WindowText {color:#123456;}".write(to: theme, atomically: true, encoding: .utf8)
            var selected = store.colorPreferences
            selected.themeFile = "user/custom.css"
            try store.validateTheme(selected)
            store.colorPreferences = selected
            #expect(failures.isEmpty && store.loadTheme(selected.themeFile).colors["WindowText"] == 0x123456, "valid custom loaded")
            try ".WindowText {color:broken;}".write(to: theme, atomically: true, encoding: .utf8)
            do {
                try store.validateTheme(selected)
                Issue.record("Appearance Settings accepted corrupted theme")
            } catch {}
            store.reloadTheme()
            #expect(
                failures.count == 1 && failures[0].themeFile == selected.themeFile && !failures[0].isBuiltin, "runtime error identifies selected theme once")
            #expect(
                failures[0].localizedDescription.contains("user-defined theme custom")
                    && failures[0].localizedDescription.contains(ApplicationThemeFailure.helpURL.absoluteString), "help and failure identity")
            #expect(store.colorPreferences.themeFile == "invariant.css" && store.preferences.theme == .light, "selection reset")
            #expect(store.loadTheme("invariant.css").colors["WindowText"] == 0, "default applied")
            for _ in 0..<10 { _ = ApplicationColors.color("WindowText", fallback: .red, store: store) }
            #expect(failures.count == 1, "repeated color access does not report again")
            #expect(make().colorPreferences.themeFile == "invariant.css" && failures.count == 1, "repair persisted and reload valid")
            try ".WindowText {color:#123456;}".write(to: theme, atomically: true, encoding: .utf8)
            store.colorPreferences = selected
            try ".WindowText {color:broken;}".write(to: theme, atomically: true, encoding: .utf8)
            store.save(store.preferences)
            #expect(
                failures.count == 2 && store.colorPreferences.themeFile == "invariant.css",
                "ordinary preference Apply reloads current theme and recovers corruption")
            for scenario in ["removed", "missing", "corrupted"] {
                var old = selected
                old.themeFile = "user/\(scenario).css"
                let path = user.appendingPathComponent(scenario + ".css")
                if scenario == "removed" {
                    try ".Control {color:red;}".write(to: path, atomically: true, encoding: .utf8)
                    store.colorPreferences = old
                    try FileManager.default.removeItem(at: path)
                } else if scenario == "corrupted" {
                    try ".Control {color:red;}".write(to: path, atomically: true, encoding: .utf8)
                    store.colorPreferences = old
                    try ".InvalidColorName {color:red;}".write(to: path, atomically: true, encoding: .utf8)
                }
                defaults.set(try JSONEncoder().encode(old), forKey: "GitExtensionsMac.colors.v1")
                let before = failures.count
                let startup = make()
                #expect(startup.colorPreferences.themeFile == "invariant.css", "startup \(scenario) reset")
                #expect(failures.count == before + 1 && failures.last?.themeFile == old.themeFile, "startup uses same recovery")
                #expect(make().colorPreferences.themeFile == "invariant.css" && failures.count == before + 1, "startup repair persisted")
            }
            var reads: [String] = []
            let fatal = ApplicationThemeRecovery.load("user/broken.css", colorblind: false) { name, _ in
                reads.append(name)
                throw ApplicationThemeError.invalid("missing default")
            }
            #expect(
                reads == ["invariant.css"] && fatal.nativeFallback && !fatal.resetSelectedTheme && fatal.failures.first?.invariant == true,
                "invariant failure follows source safe fallback without recursion")
            reads = []
            let doubleFailure = ApplicationThemeRecovery.load("user/broken.css", colorblind: true) { name, variation in
                reads.append(name)
                if name == "invariant.css" && !variation { return ["WindowText": 0] }
                throw ApplicationThemeError.invalid("broken source")
            }
            #expect(
                reads.count == 3 && doubleFailure.nativeFallback && doubleFailure.resetSelectedTheme && doubleFailure.failures.count == 2,
                "selected/default variation double failure terminates safely")
            var reports = 0
            var calls = 0
            let runtime = ApplicationThemeRuntime(
                reader: { _, _ in
                    calls += 1
                    throw ApplicationThemeError.invalid("failed invariant")
                }, report: { _ in reports += 1 })
            for _ in 0..<10 { _ = runtime.load("user/broken.css", colorblind: false) }
            #expect(calls == 1 && reports == 1, "default failure cached, no retry loop")
        }

        @Test("Settings") static func settings() async throws {
            let domain = "Appearance-ThemeSettings-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: domain)!
            let previousPage = SettingsViewController.lastSelectedPage
            defer {
                defaults.removePersistentDomain(forName: domain)
                SettingsViewController.lastSelectedPage = previousPage
            }
            let user = FileManager.default.temporaryDirectory.appendingPathComponent("Appearance-SettingsThemes-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: user) }
            var failures: [ApplicationThemeFailure] = []
            let store = AppSettingsStore(defaults: defaults, bundledThemes: sourceThemes, userThemes: user, themeFailureReporter: { failures.append($0) })
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func make() -> (SettingsViewController, NSPanel) {
                let controller = SettingsViewController(store: store, source: nil, initialPage: "colors", repositoryChanged: {})
                let panel = NSPanel(contentViewController: controller)
                panel.isReleasedWhenClosed = false
                controller.panel = panel
                return (controller, panel)
            }
            func choose(_ controller: SettingsViewController, _ name: String) {
                let popup = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("invariant.css") }!
                popup.selectItem(withTitle: name)
                _ = popup.sendAction(popup.action!, to: popup.target)
            }
            func button(_ controller: SettingsViewController, _ title: String) -> NSButton {
                descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title }!
            }
            let (cancelled, cancelPanel) = make()
            defer { cancelPanel.close() }
            choose(cancelled, "dark.css")
            button(cancelled, "Cancel").performClick(nil)
            #expect(store.colorPreferences.themeFile.isEmpty, "Cancel leaves persisted theme unchanged")
            let (applied, applyPanel) = make()
            defer { applyPanel.close() }
            choose(applied, "dark.css")
            let apply = button(applied, "Apply")
            apply.performClick(nil)
            for _ in 0..<200 where !apply.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
            #expect(apply.isEnabled && store.colorPreferences.themeFile == "dark.css", "Apply persists selected theme")
            #expect(store.loadTheme("dark.css").failures.isEmpty, "Apply uses runtime loader")
            let (accepted, okPanel) = make()
            defer { okPanel.close() }
            choose(accepted, "light+.css")
            let ok = button(accepted, "OK")
            ok.performClick(nil)
            for _ in 0..<200 where !ok.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
            #expect(store.colorPreferences.themeFile == "light+.css" && failures.isEmpty, "OK persists and loads selected theme")
            let custom = user.appendingPathComponent("custom.css")
            try ".Control {color:red;}".write(to: custom, atomically: true, encoding: .utf8)
            var selected = store.colorPreferences
            selected.themeFile = "user/custom.css"
            store.colorPreferences = selected
            let (corrupted, corruptedPanel) = make()
            defer { corruptedPanel.close() }
            try ".UnknownColor {color:red;}".write(to: custom, atomically: true, encoding: .utf8)
            button(corrupted, "Apply").performClick(nil)
            #expect(
                failures.count == 1 && store.colorPreferences.themeFile == "invariant.css", "Settings detects saved-theme corruption and uses runtime recovery")
            let repairedPopup = descendants(corrupted.view).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("invariant.css") }!
            #expect(repairedPopup.titleOfSelectedItem == "invariant.css", "Settings draft shows repaired default")
            let repairedApply = button(corrupted, "Apply")
            repairedApply.performClick(nil)
            for _ in 0..<200 where !repairedApply.isEnabled { try await Task.sleep(for: .milliseconds(10)) }
            #expect(
                repairedApply.isEnabled && failures.count == 1 && store.colorPreferences.themeFile == "invariant.css",
                "Apply after repair neither retries broken theme nor reintroduces stale draft")
        }
    }
}

typealias AppearanceTests = UIIntegrationTests.AppearanceTests
