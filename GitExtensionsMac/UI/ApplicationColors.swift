import AppKit

struct ApplicationColorPreferences: Codable, Equatable {
    var themeFile = ""
    var colorblind = false
    var multicolorBranches = true
    var nonRelativeGraphGray = true
    var fillRefLabels = false
    var alternateRows = true
    var highlightAuthored = true
    var nonRelativeTextGray = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case themeFile, colorblind, multicolorBranches, nonRelativeGraphGray, fillRefLabels, alternateRows, highlightAuthored, nonRelativeTextGray
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        themeFile = try values.decodeIfPresent(String.self, forKey: .themeFile) ?? ""
        colorblind = try values.decodeIfPresent(Bool.self, forKey: .colorblind) ?? false
        multicolorBranches = try values.decodeIfPresent(Bool.self, forKey: .multicolorBranches) ?? true
        nonRelativeGraphGray = try values.decodeIfPresent(Bool.self, forKey: .nonRelativeGraphGray) ?? true
        fillRefLabels = try values.decodeIfPresent(Bool.self, forKey: .fillRefLabels) ?? false
        alternateRows = try values.decodeIfPresent(Bool.self, forKey: .alternateRows) ?? true
        highlightAuthored = try values.decodeIfPresent(Bool.self, forKey: .highlightAuthored) ?? true
        nonRelativeTextGray = try values.decodeIfPresent(Bool.self, forKey: .nonRelativeTextGray) ?? false
    }
}

enum ApplicationThemeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let description): description }
    }
}

enum ApplicationThemeReader {
    static var bundledDirectory: URL { Bundle.main.resourceURL!.appendingPathComponent("Themes") }
    static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitExtensionsMac/Themes", isDirectory: true)
    }
    static func availableThemes() -> [String] {
        let user = (try? FileManager.default.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        return ["invariant.css", "light+.css", "dark.css", "dark+.css"]
            + user.filter { $0.pathExtension.lowercased() == "css" }.map { "user/" + $0.lastPathComponent }.sorted()
    }
    static func load(_ name: String, colorblind: Bool, bundled: URL = bundledDirectory, user: URL = userDirectory) throws -> [String: Int] {
        struct Entry { let specificity: Int; let value: Int? }
        var entries: [String: Entry] = [:]
        func resolve(_ name: String) throws -> URL {
            let isUser = name.hasPrefix("user/") || name.hasPrefix("{UserAppData}/")
            let relative = name.replacingOccurrences(of: "{UserAppData}/", with: "").replacingOccurrences(of: "user/", with: "")
            guard !relative.isEmpty, (relative as NSString).lastPathComponent == relative, relative.hasSuffix(".css") else {
                throw ApplicationThemeError.invalid("Invalid theme import: \(name)")
            }
            return (isUser ? user : bundled).appendingPathComponent(relative)
        }
        func read(_ name: String, chain: Set<URL>) throws {
            let url = try resolve(name).resolvingSymlinksInPath()
            guard !chain.contains(url), chain.count < 32 else { throw ApplicationThemeError.invalid("Cyclic theme import: \(name)") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw ApplicationThemeError.invalid("Theme exceeds 1 MB: \(name)") }
            var text = try String(contentsOf: url, encoding: .utf8)
            let comments = try NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#)
            text = comments.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            let imports = try NSRegularExpression(pattern: #"@import\s+url\(\s*["']?([^"')]+)["']?\s*\)\s*;"#)
            for match in imports.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                try read((text as NSString).substring(with: match.range(at: 1)), chain: chain.union([url]))
            }
            text = imports.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            let rules = try NSRegularExpression(pattern: #"([^{}]+)\{([^{}]*)\}"#)
            for match in rules.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let selector = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let body = (text as NSString).substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard selector.hasPrefix("."), !selector.contains(where: { $0.isWhitespace }) else { throw ApplicationThemeError.invalid("Invalid theme selector: \(selector)") }
                let classes = selector.dropFirst().split(separator: ".").map(String.init)
                guard let key = classes.first else { continue }
                guard classes.dropFirst().allSatisfy({ $0 == "colorblind" && colorblind }) else { continue }
                if let previous = entries[key], previous.specificity > classes.count { continue }
                let value: Int?
                if body.isEmpty && key.hasPrefix("GraphBranch") { value = nil }
                else {
                    let declaration = try NSRegularExpression(pattern: #"(?:^|;)\s*color\s*:\s*([^;]+)"#)
                    guard let color = declaration.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                          let parsed = parseColor((body as NSString).substring(with: color.range(at: 1))) else {
                        throw ApplicationThemeError.invalid("Invalid theme color: \(selector)")
                    }
                    value = parsed
                }
                entries[key] = Entry(specificity: classes.count, value: value)
            }
        }
        try read(name, chain: [])
        return entries.mapValues { $0.value ?? -1 }
    }

    static func parseColor(_ value: String) -> Int? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            let digits = String(value.dropFirst())
            guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            if digits.count == 6 { return Int(digits, radix: 16) }
            if digits.count == 3 { return Int(digits.map { "\($0)\($0)" }.joined(), radix: 16) }
        }
        if value.hasPrefix("rgb("), value.hasSuffix(")") {
            let fields = value.dropFirst(4).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let components = fields.compactMap { field -> Int? in
                let component = field.trimmingCharacters(in: .whitespaces)
                if component.hasSuffix("%") {
                    guard let percent = Double(component.dropLast()), percent.isFinite, (0...100).contains(percent) else { return nil }
                    return Int((percent * 255 / 100).rounded())
                }
                return Int(component)
            }
            if components.count == 3, components.allSatisfy({ (0...255).contains($0) }) { return components[0] << 16 | components[1] << 8 | components[2] }
        }
        if value.hasPrefix("hsl("), value.hasSuffix(")") {
            let fields = value.dropFirst(4).dropLast().split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3, fields[1].hasSuffix("%"), fields[2].hasSuffix("%"),
                  let hue = Double(fields[0]), hue.isFinite,
                  let saturation = Double(fields[1].dropLast()), (0...100).contains(saturation),
                  let lightness = Double(fields[2].dropLast()), (0...100).contains(lightness) else { return nil }
            let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let l = lightness / 100
            let c = (1 - abs(2 * l - 1)) * saturation / 100
            let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let rgb: [Double] = switch Int(h) {
            case 0: [c, x, 0]
            case 1: [x, c, 0]
            case 2: [0, c, x]
            case 3: [0, x, c]
            case 4: [x, 0, c]
            default: [c, 0, x]
            }
            let components = rgb.map { Int((($0 + l - c / 2) * 255).rounded()) }
            return components[0] << 16 | components[1] << 8 | components[2]
        }
        return namedColors[value]
    }

    private static let namedColors: [String: Int] = [
        "aliceblue": 0xF0F8FF,
        "antiquewhite": 0xFAEBD7,
        "aqua": 0x00FFFF,
        "aquamarine": 0x7FFFD4,
        "azure": 0xF0FFFF,
        "beige": 0xF5F5DC,
        "bisque": 0xFFE4C4,
        "black": 0x000000,
        "blanchedalmond": 0xFFEBCD,
        "blue": 0x0000FF,
        "blueviolet": 0x8A2BE2,
        "brown": 0xA52A2A,
        "burlywood": 0xDEB887,
        "cadetblue": 0x5F9EA0,
        "chartreuse": 0x7FFF00,
        "chocolate": 0xD2691E,
        "coral": 0xFF7F50,
        "cornflowerblue": 0x6495ED,
        "cornsilk": 0xFFF8DC,
        "crimson": 0xDC143C,
        "cyan": 0x00FFFF,
        "darkblue": 0x00008B,
        "darkcyan": 0x008B8B,
        "darkgoldenrod": 0xB8860B,
        "darkgray": 0xA9A9A9,
        "darkgreen": 0x006400,
        "darkgrey": 0xA9A9A9,
        "darkkhaki": 0xBDB76B,
        "darkmagenta": 0x8B008B,
        "darkolivegreen": 0x556B2F,
        "darkorange": 0xFF8C00,
        "darkorchid": 0x9932CC,
        "darkred": 0x8B0000,
        "darksalmon": 0xE9967A,
        "darkseagreen": 0x8FBC8F,
        "darkslateblue": 0x483D8B,
        "darkslategray": 0x2F4F4F,
        "darkslategrey": 0x2F4F4F,
        "darkturquoise": 0x00CED1,
        "darkviolet": 0x9400D3,
        "deeppink": 0xFF1493,
        "deepskyblue": 0x00BFFF,
        "dimgray": 0x696969,
        "dimgrey": 0x696969,
        "dodgerblue": 0x1E90FF,
        "firebrick": 0xB22222,
        "floralwhite": 0xFFFAF0,
        "forestgreen": 0x228B22,
        "fuchsia": 0xFF00FF,
        "gainsboro": 0xDCDCDC,
        "ghostwhite": 0xF8F8FF,
        "gold": 0xFFD700,
        "goldenrod": 0xDAA520,
        "gray": 0x808080,
        "green": 0x008000,
        "greenyellow": 0xADFF2F,
        "grey": 0x808080,
        "honeydew": 0xF0FFF0,
        "hotpink": 0xFF69B4,
        "indianred": 0xCD5C5C,
        "indigo": 0x4B0082,
        "ivory": 0xFFFFF0,
        "khaki": 0xF0E68C,
        "lavender": 0xE6E6FA,
        "lavenderblush": 0xFFF0F5,
        "lawngreen": 0x7CFC00,
        "lemonchiffon": 0xFFFACD,
        "lightblue": 0xADD8E6,
        "lightcoral": 0xF08080,
        "lightcyan": 0xE0FFFF,
        "lightgoldenrodyellow": 0xFAFAD2,
        "lightgray": 0xD3D3D3,
        "lightgreen": 0x90EE90,
        "lightgrey": 0xD3D3D3,
        "lightpink": 0xFFB6C1,
        "lightsalmon": 0xFFA07A,
        "lightseagreen": 0x20B2AA,
        "lightskyblue": 0x87CEFA,
        "lightslategray": 0x778899,
        "lightslategrey": 0x778899,
        "lightsteelblue": 0xB0C4DE,
        "lightyellow": 0xFFFFE0,
        "lime": 0x00FF00,
        "limegreen": 0x32CD32,
        "linen": 0xFAF0E6,
        "magenta": 0xFF00FF,
        "maroon": 0x800000,
        "mediumaquamarine": 0x66CDAA,
        "mediumblue": 0x0000CD,
        "mediumorchid": 0xBA55D3,
        "mediumpurple": 0x9370DB,
        "mediumseagreen": 0x3CB371,
        "mediumslateblue": 0x7B68EE,
        "mediumspringgreen": 0x00FA9A,
        "mediumturquoise": 0x48D1CC,
        "mediumvioletred": 0xC71585,
        "midnightblue": 0x191970,
        "mintcream": 0xF5FFFA,
        "mistyrose": 0xFFE4E1,
        "moccasin": 0xFFE4B5,
        "navajowhite": 0xFFDEAD,
        "navy": 0x000080,
        "oldlace": 0xFDF5E6,
        "olive": 0x808000,
        "olivedrab": 0x6B8E23,
        "orange": 0xFFA500,
        "orangered": 0xFF4500,
        "orchid": 0xDA70D6,
        "palegoldenrod": 0xEEE8AA,
        "palegreen": 0x98FB98,
        "paleturquoise": 0xAFEEEE,
        "palevioletred": 0xDB7093,
        "papayawhip": 0xFFEFD5,
        "peachpuff": 0xFFDAB9,
        "peru": 0xCD853F,
        "pink": 0xFFC0CB,
        "plum": 0xDDA0DD,
        "powderblue": 0xB0E0E6,
        "purple": 0x800080,
        "rebeccapurple": 0x663399,
        "red": 0xFF0000,
        "rosybrown": 0xBC8F8F,
        "royalblue": 0x4169E1,
        "saddlebrown": 0x8B4513,
        "salmon": 0xFA8072,
        "sandybrown": 0xF4A460,
        "seagreen": 0x2E8B57,
        "seashell": 0xFFF5EE,
        "sienna": 0xA0522D,
        "silver": 0xC0C0C0,
        "skyblue": 0x87CEEB,
        "slateblue": 0x6A5ACD,
        "slategray": 0x708090,
        "slategrey": 0x708090,
        "snow": 0xFFFAFA,
        "springgreen": 0x00FF7F,
        "steelblue": 0x4682B4,
        "tan": 0xD2B48C,
        "teal": 0x008080,
        "thistle": 0xD8BFD8,
        "tomato": 0xFF6347,
        "turquoise": 0x40E0D0,
        "violet": 0xEE82EE,
        "wheat": 0xF5DEB3,
        "white": 0xFFFFFF,
        "whitesmoke": 0xF5F5F5,
        "yellow": 0xFFFF00,
        "yellowgreen": 0x9ACD32
    ]
}

@MainActor
enum ApplicationColors {
    private static var cache: [String: [String: Int]] = [:]
    private(set) static var generation = 0
    static func invalidate() { cache = [:]; generation &+= 1 }
    private static func colors(_ name: String, colorblind: Bool) -> [String: Int]? {
        let key = name + String(colorblind)
        if let cached = cache[key] { return cached }
        guard let loaded = try? ApplicationThemeReader.load(name, colorblind: colorblind) else { return nil }
        cache[key] = loaded
        return loaded
    }
    static func color(_ name: String, fallback: NSColor) -> NSColor {
        let preferences = AppSettingsStore.shared.colorPreferences
        guard !preferences.themeFile.isEmpty || preferences.colorblind else { return fallback }
        if preferences.themeFile.isEmpty, AppSettingsStore.shared.preferences.theme == .system {
            let light = colors("invariant.css", colorblind: preferences.colorblind)?[name]
            let dark = colors("dark.css", colorblind: preferences.colorblind)?[name]
            return NSColor(name: nil) { appearance in
                guard let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light else { return fallback }
                if value < 0 { return .clear }
                return NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
            }
        }
        let selected = preferences.themeFile.isEmpty ? (AppSettingsStore.shared.preferences.theme == .dark ? "dark.css" : "invariant.css") : preferences.themeFile
        guard let values = colors(selected, colorblind: preferences.colorblind) else { return fallback }
        guard let value = values[name] else { return fallback }
        if value < 0 { return .clear }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
