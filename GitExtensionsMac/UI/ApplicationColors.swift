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
    static func availableThemes(user directory: URL = userDirectory) -> [String] {
        let user = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return ["invariant.css", "light+.css", "dark.css", "dark+.css"]
            + user.filter { $0.pathExtension.lowercased() == "css" }.map { "user/" + $0.lastPathComponent }.sorted()
    }
    static func resolve(_ name: String, bundled: URL = bundledDirectory, user: URL = userDirectory) -> URL {
        let isUser = name.hasPrefix("user/") || name.hasPrefix("{UserAppData}/")
        var relative = isUser ? String(name.dropFirst(name.hasPrefix("user/") ? 5 : 14)) : name
        if relative.lowercased().hasSuffix(".css") { relative = String(relative.dropLast(4)) }
        if !isUser && ["light", "invariant"].contains(relative.lowercased()) { relative = "invariant" }
        return (isUser ? user : bundled).appendingPathComponent(relative + ".css")
    }

    static let applicationColorNames: [String] = [
        "PanelBackground", "EditorBackground", "LineNumberBackground", "AuthoredHighlight", "Selection",
        "HighlightAllOccurences", "InactiveSelectionHighlight",
        "GraphBranch1", "GraphBranch2", "GraphBranch3", "GraphBranch4", "GraphBranch5", "GraphBranch6", "GraphBranch7", "GraphBranch8",
        "GraphNonRelativeBranch", "Branch", "RemoteBranch", "Tag", "OtherTag", "DiffSection"
    ] + ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"].flatMap { color in
        ["ForeNormal", "BackNormal", "ForeBold", "BackBold"].map { "AnsiTerminal" + color + $0 }
    }

    static let systemColorNames = "ActiveBorder,ActiveCaption,ActiveCaptionText,AppWorkspace,Control,ControlDark,ControlDarkDark,ControlLight,ControlLightLight,ControlText,Desktop,GrayText,Highlight,HighlightText,HotTrack,InactiveBorder,InactiveCaption,InactiveCaptionText,Info,InfoText,Menu,MenuText,ScrollBar,Window,WindowFrame,WindowText,ButtonFace,ButtonHighlight,ButtonShadow,GradientActiveCaption,GradientInactiveCaption,MenuBar,MenuHighlight,RebeccaPurple".split(separator: ",").map(String.init)

    private static let knownColorNames: Set<String> = Set("ActiveBorder,ActiveCaption,ActiveCaptionText,AppWorkspace,Control,ControlDark,ControlDarkDark,ControlLight,ControlLightLight,ControlText,Desktop,GrayText,Highlight,HighlightText,HotTrack,InactiveBorder,InactiveCaption,InactiveCaptionText,Info,InfoText,Menu,MenuText,ScrollBar,Window,WindowFrame,WindowText,Transparent,AliceBlue,AntiqueWhite,Aqua,Aquamarine,Azure,Beige,Bisque,Black,BlanchedAlmond,Blue,BlueViolet,Brown,BurlyWood,CadetBlue,Chartreuse,Chocolate,Coral,CornflowerBlue,Cornsilk,Crimson,Cyan,DarkBlue,DarkCyan,DarkGoldenrod,DarkGray,DarkGreen,DarkKhaki,DarkMagenta,DarkOliveGreen,DarkOrange,DarkOrchid,DarkRed,DarkSalmon,DarkSeaGreen,DarkSlateBlue,DarkSlateGray,DarkTurquoise,DarkViolet,DeepPink,DeepSkyBlue,DimGray,DodgerBlue,Firebrick,FloralWhite,ForestGreen,Fuchsia,Gainsboro,GhostWhite,Gold,Goldenrod,Gray,Green,GreenYellow,Honeydew,HotPink,IndianRed,Indigo,Ivory,Khaki,Lavender,LavenderBlush,LawnGreen,LemonChiffon,LightBlue,LightCoral,LightCyan,LightGoldenrodYellow,LightGray,LightGreen,LightPink,LightSalmon,LightSeaGreen,LightSkyBlue,LightSlateGray,LightSteelBlue,LightYellow,Lime,LimeGreen,Linen,Magenta,Maroon,MediumAquamarine,MediumBlue,MediumOrchid,MediumPurple,MediumSeaGreen,MediumSlateBlue,MediumSpringGreen,MediumTurquoise,MediumVioletRed,MidnightBlue,MintCream,MistyRose,Moccasin,NavajoWhite,Navy,OldLace,Olive,OliveDrab,Orange,OrangeRed,Orchid,PaleGoldenrod,PaleGreen,PaleTurquoise,PaleVioletRed,PapayaWhip,PeachPuff,Peru,Pink,Plum,PowderBlue,Purple,Red,RosyBrown,RoyalBlue,SaddleBrown,Salmon,SandyBrown,SeaGreen,SeaShell,Sienna,Silver,SkyBlue,SlateBlue,SlateGray,Snow,SpringGreen,SteelBlue,Tan,Teal,Thistle,Tomato,Turquoise,Violet,Wheat,White,WhiteSmoke,Yellow,YellowGreen,ButtonFace,ButtonHighlight,ButtonShadow,GradientActiveCaption,GradientInactiveCaption,MenuBar,MenuHighlight,RebeccaPurple".split(separator: ",").map(String.init))

    static func load(_ name: String, colorblind: Bool, bundled: URL = bundledDirectory, user: URL = userDirectory) throws -> [String: Int] {
        struct Entry { let specificity: Int; let value: Int }
        var entries: [String: Entry] = [:]
        func read(_ name: String, chain: Set<String>) throws {
            let url = resolve(name, bundled: bundled, user: user).resolvingSymlinksInPath()
            let identity = url.path.lowercased()
            guard !chain.contains(identity), chain.count < 32 else { throw ApplicationThemeError.invalid("Cycling CSS import: \(name)") }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else {
                throw ApplicationThemeError.invalid("Theme file size exceeds 1,048,576 bytes: \(name)")
            }
            let data = try Data(contentsOf: url)
            let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE, 0, 0]) || data.starts(with: [0, 0, 0xFE, 0xFF]) ? .utf32
                : data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
            guard var text = String(data: data, encoding: encoding) else { throw ApplicationThemeError.invalid("Invalid theme encoding: \(name)") }
            if text.first == "\u{FEFF}" { text.removeFirst() }
            let comments = try NSRegularExpression(pattern: #"/\*[\s\S]*?(?:\*/|$)"#)
            text = comments.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            let imports = try NSRegularExpression(pattern: #"@import\s+(?:url\(\s*["']?([^"')]+?)["']?\s*\)|["']([^"']+)["'])[^;]*;"#)
            for match in imports.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
                try read((text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines), chain: chain.union([identity]))
            }
            text = imports.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            let rules = try NSRegularExpression(pattern: #"([^{}]+)\{([^{}]*)(?:\}|$)"#)
            for match in rules.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let selector = (text as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let body = (text as NSString).substring(with: match.range(at: 2))
                let value = try ruleColor(body, selector: selector)
                guard selector.hasPrefix(".") else { throw ApplicationThemeError.invalid("Invalid CSS rule '\(selector)'") }
                let classes = selector.dropFirst().split(separator: ".").map(String.init)
                guard let key = classes.first else { throw ApplicationThemeError.invalid("Invalid CSS rule '\(selector)'") }
                guard classes.dropFirst().allSatisfy({ $0 == "colorblind" && colorblind }) else { continue }
                if let previous = entries[key], previous.specificity > classes.count { continue }
                if key == "Graph" { continue }
                guard applicationColorNames.contains(key) || knownColorNames.contains(key) else {
                    throw ApplicationThemeError.invalid("Unknown color name \"\(key)\"")
                }
                entries[key] = Entry(specificity: classes.count, value: value)
            }
        }
        do { try read(name, chain: []) }
        catch { throw ApplicationThemeError.invalid("Failed to load \(name): \(error.localizedDescription)") }
        return entries.mapValues(\.value)
    }

    private enum CSSColor {
        case rgb(Int), unsupported, invalid
    }

    private static func cssColor(_ source: String) -> CSSColor {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            let digits = String(value.dropFirst())
            guard [3, 6].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return .invalid }
            return .rgb(Int(digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : digits, radix: 16)!)
        }
        if let named = namedColors[value] ?? cssSystemColors[value] { return .rgb(named) }
        if value.hasPrefix("rgb("), value.hasSuffix(")") {
            let fields = value.dropFirst(4).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return .invalid }
            var components: [Int] = []
            for field in fields {
                let component = field.trimmingCharacters(in: .whitespacesAndNewlines)
                if component.hasSuffix("%") {
                    let number = String(component.dropLast())
                    guard number.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
                          let percent = Float(number), percent.isFinite else { return .invalid }
                    let scaled = Double(255 * (percent * 0.01))
                    guard scaled.isFinite else { return .invalid }
                    components.append((Int(scaled.truncatingRemainder(dividingBy: 256)) + 256) % 256)
                } else {
                    guard let byte = Int32(component), byte >= 0 else { return .invalid }
                    components.append(Int(min(byte, 255)))
                }
            }
            return .rgb(components[0] << 16 | components[1] << 8 | components[2])
        }
        if ["transparent", "inherit", "initial"].contains(value) { return .unsupported }
        if value.hasPrefix("hsl("), parseColor(value) != nil { return .unsupported }
        if value.hasPrefix("rgba(") || value.hasPrefix("hsla(") {
            let fields = value.dropFirst(5).dropLast().split(separator: ",", omittingEmptySubsequences: false)
            guard value.hasSuffix(")"), fields.count == 4, let alpha = Double(fields[3].trimmingCharacters(in: .whitespacesAndNewlines)), alpha.isFinite else { return .invalid }
            let base = (value.hasPrefix("rgba(") ? "rgb(" : "hsl(") + fields.prefix(3).joined(separator: ",") + ")"
            if parseColor(base) != nil { return .unsupported }
        }
        return .invalid
    }

    private static let cssSystemColors: [String: Int] = [
        "background": 0x6363CE,
        "buttontext": 0x000000,
        "captiontext": 0x000000,
        "infobackground": 0xFBFCC5,
        "threeddarkshadow": 0x666666,
        "threedface": 0xFFFFFF,
        "threedhighlight": 0xDDDDDD,
        "threedlightshadow": 0xC0C0C0,
        "threedshadow": 0x888888,
        "activeborder": 0xFFFFFF,
        "activecaption": 0xCCCCCC,
        "appworkspace": 0xFFFFFF,
        "graytext": 0x808080,
        "highlight": 0xB5D5FF,
        "highlighttext": 0x000000,
        "inactiveborder": 0xFFFFFF,
        "inactivecaption": 0xFFFFFF,
        "inactivecaptiontext": 0x7F7F7F,
        "infotext": 0x000000,
        "menu": 0xF7F7F7,
        "menutext": 0x000000,
        "scrollbar": 0xFFFFFF,
        "window": 0xFFFFFF,
        "windowframe": 0xCCCCCC,
        "windowtext": 0x000000,
        "buttonface": 0xDDDDDD,
        "buttonhighlight": 0xDDDDDD,
        "buttonshadow": 0x888888
    ]

    private static func ruleColor(_ body: String, selector: String) throws -> Int {
        var selected: CSSColor = .invalid
        var important = false
        for declaration in body.split(separator: ";", omittingEmptySubsequences: false) {
            guard let colon = declaration.firstIndex(of: ":"), declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "color" else { continue }
            var value = String(declaration[declaration.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let priority = value.hasSuffix("!important")
            if priority { value = String(value.dropLast(10)).trimmingCharacters(in: .whitespacesAndNewlines) }
            let parsed = cssColor(value)
            if case .invalid = parsed { continue }
            if important && !priority { continue }
            selected = parsed; important = priority
        }
        switch selected {
        case .rgb(let value): return value
        case .invalid where selector.hasPrefix(".GraphBranch"): return -1
        default: throw ApplicationThemeError.invalid("Invalid CSS rule '\(selector)'")
        }
    }

    static func formatColor(_ value: Int) -> String { String(format: "#%06x", (value == -1 ? 0 : value) & 0xFFFFFF) }

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

struct ApplicationThemeFailure: LocalizedError, Hashable {
    static let helpURL = URL(string: "https://github.com/gitextensions/gitextensions/wiki/Dark-Mode")!
    let themeFile: String
    let colorblind: Bool
    let invariant: Bool
    let detail: String

    var isBuiltin: Bool { !themeFile.hasPrefix("user/") && !themeFile.hasPrefix("{UserAppData}/") }
    var themeName: String { ((themeFile as NSString).lastPathComponent as NSString).deletingPathExtension }
    var errorDescription: String? {
        let identity = invariant ? "invariant theme" : "\(isBuiltin ? "preinstalled" : "user-defined") theme \(themeName)\(colorblind ? ".colorblind" : "")"
        return "Failed to load \(identity): \(detail)\n\nSee also \(Self.helpURL.absoluteString)"
    }
}

struct ApplicationThemeLoadResult: Equatable {
    let themeFile: String
    let colors: [String: Int]
    let resetSelectedTheme: Bool
    let nativeFallback: Bool
    let failures: [ApplicationThemeFailure]
}

enum ApplicationThemeRecovery {
    static let defaultThemeFile = "invariant.css"

    static func load(_ selected: String, colorblind: Bool,
                     reader: (String, Bool) throws -> [String: Int]) -> ApplicationThemeLoadResult {
        let invariant: [String: Int]
        do { invariant = try reader(defaultThemeFile, false) }
        catch {
            return ApplicationThemeLoadResult(themeFile: selected, colors: [:], resetSelectedTheme: false, nativeFallback: true,
                failures: [ApplicationThemeFailure(themeFile: defaultThemeFile, colorblind: false, invariant: true, detail: error.localizedDescription)])
        }
        do {
            let values = selected == defaultThemeFile && !colorblind ? invariant : try reader(selected, colorblind)
            return ApplicationThemeLoadResult(themeFile: selected, colors: values, resetSelectedTheme: false, nativeFallback: false, failures: [])
        } catch {
            let failure = ApplicationThemeFailure(themeFile: selected, colorblind: colorblind, invariant: false, detail: error.localizedDescription)
            if selected == defaultThemeFile || !colorblind {
                return ApplicationThemeLoadResult(themeFile: defaultThemeFile, colors: invariant, resetSelectedTheme: true, nativeFallback: false, failures: [failure])
            }
            do {
                let values = try reader(defaultThemeFile, colorblind)
                return ApplicationThemeLoadResult(themeFile: defaultThemeFile, colors: values, resetSelectedTheme: true, nativeFallback: false, failures: [failure])
            } catch {
                let fallbackFailure = ApplicationThemeFailure(themeFile: defaultThemeFile, colorblind: colorblind, invariant: true, detail: error.localizedDescription)
                return ApplicationThemeLoadResult(themeFile: defaultThemeFile, colors: [:], resetSelectedTheme: true, nativeFallback: true, failures: [failure, fallbackFailure])
            }
        }
    }
}

@MainActor
final class ApplicationThemeRuntime {
    private struct Key: Hashable { let name: String; let colorblind: Bool }
    private let reader: (String, Bool) throws -> [String: Int]
    private let report: (ApplicationThemeFailure) -> Void
    private var values: [Key: [String: Int]] = [:]
    private var results: [Key: ApplicationThemeLoadResult] = [:]
    private var reported: Set<ApplicationThemeFailure> = []

    init(reader: @escaping (String, Bool) throws -> [String: Int], report: @escaping (ApplicationThemeFailure) -> Void) {
        self.reader = reader; self.report = report
    }

    func load(_ name: String, colorblind: Bool) -> ApplicationThemeLoadResult {
        let key = Key(name: name, colorblind: colorblind)
        if let cached = results[key] { return cached }
        let result = ApplicationThemeRecovery.load(name, colorblind: colorblind) { name, variation in
            let key = Key(name: name, colorblind: variation)
            if let cached = self.values[key] { return cached }
            let loaded = try self.reader(name, variation)
            self.values[key] = loaded
            return loaded
        }
        results[key] = result
        if result.resetSelectedTheme {
            results[Key(name: result.themeFile, colorblind: colorblind)] = ApplicationThemeLoadResult(
                themeFile: result.themeFile, colors: result.colors, resetSelectedTheme: false,
                nativeFallback: result.nativeFallback, failures: [])
        }
        for failure in result.failures where reported.insert(failure).inserted { report(failure) }
        return result
    }

    func invalidate() { values = [:]; results = [:]; reported = [] }
}

@MainActor
enum ApplicationColors {
    private(set) static var generation = 0
    static func invalidate() { generation &+= 1 }
    static func color(_ name: String, fallback: NSColor) -> NSColor {
        color(name, fallback: fallback, store: .shared)
    }
    static func color(_ name: String, fallback: NSColor, store: AppSettingsStore) -> NSColor {
        var preferences = store.colorPreferences
        guard !preferences.themeFile.isEmpty || preferences.colorblind else { return fallback }
        if preferences.themeFile.isEmpty, store.preferences.theme == .system {
            let light = store.loadTheme("invariant.css").colors[name]
            let dark = store.loadTheme("dark.css").colors[name]
            preferences = store.colorPreferences
            if !preferences.themeFile.isEmpty { return color(name, fallback: fallback, store: store) }
            return NSColor(name: nil) { appearance in
                guard let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light else { return fallback }
                return fixedColor(value)
            }
        }
        let selected = preferences.themeFile.isEmpty ? (store.preferences.theme == .dark ? "dark.css" : "invariant.css") : preferences.themeFile
        guard let value = store.loadTheme(selected).colors[name] else { return fallback }
        return fixedColor(value)
    }
    static func blended(_ color: NSColor, fraction: CGFloat, of other: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = color
            appearance.performAsCurrentDrawingAppearance { result = color.blended(withFraction: fraction, of: other) ?? color }
            return result
        }
    }
    static func resolved(_ color: NSColor, for view: NSView) -> CGColor {
        var result = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
    private static func fixedColor(_ value: Int) -> NSColor {
        if value < 0 { return .clear }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
