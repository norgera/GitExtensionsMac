import GitExtensionsCore
import GitCommands
import AppKit

final class SplitToolbarPopUpButton: NSPopUpButton {
    var onPrimaryClick: (() -> Void)?
    static let arrowWidth: CGFloat = 12
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < bounds.width - Self.arrowWidth, let onPrimaryClick {
            highlight(true)
            onPrimaryClick()
            highlight(false)
            return
        }
        super.mouseDown(with: event)
    }
}

final class PersistentMenuChoiceView: NSView {
    private weak var item: NSMenuItem?
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(item: NSMenuItem) {
        self.item = item
        let width = ceil((item.title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width) + 68
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { _ = accessibilityPerformPress() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76: _ = accessibilityPerformPress()
        case 53: item?.menu?.cancelTracking()
        case 125, 126:
            guard let views = item?.menu?.items.compactMap({ $0.view as? PersistentMenuChoiceView }),
                  let index = views.firstIndex(of: self), !views.isEmpty else { return }
            let next = views[(index + (event.keyCode == 125 ? 1 : views.count - 1)) % views.count]
            hovered = false
            needsDisplay = true
            next.hovered = true
            next.needsDisplay = true
            window?.makeFirstResponder(next)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let item, item.isEnabled, let action = item.action else { return false }
        let result = NSApp.sendAction(action, to: item.target, from: item)
        setAccessibilityValue(item.state == .on ? 1 : 0)
        needsDisplay = true
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let color: NSColor = hovered ? .selectedMenuItemTextColor : .labelColor
        if item.state == .on {
            ("✓" as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: color])
        }
        item.image?.draw(in: NSRect(x: 28, y: 4, width: 16, height: 16))
        (item.title as NSString).draw(at: NSPoint(x: 50, y: 4), withAttributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: color])
    }
}

enum BrowserMetrics {
    static let primaryToolbarHeight: CGFloat = 25
    static let filterToolbarHeight: CGFloat = 25
    static let statusHeight: CGFloat = 22
    @MainActor static var revisionRowHeight: CGFloat { AppSettingsStore.shared.applicationRowHeight(minimum: 22) }
    @MainActor static var fileRowHeight: CGFloat { AppSettingsStore.shared.applicationRowHeight(minimum: 18) }
    static let diffRowHeight: CGFloat = 18
}

enum AppKitFactory {
    @MainActor
    static func applyRevisionCopyImages(to menu: NSMenu) {
        for (id, image) in [("revision.copy", "CopyToClipboard"), ("revision.copy.hash", "CommitId"),
                            ("revision.copy.message", "Message"), ("revision.copy.author", "Author"),
                            ("revision.copy.date", "Date"), ("revision.copy.authorDate", "Date"), ("revision.copy.commitDate", "Date")] {
            if let item = menuItem(withIdentifier: id, in: menu) { setMenuImage(image, for: item) }
        }
        guard let submenu = menuItem(withIdentifier: "revision.copy", in: menu)?.submenu else { return }
        var image: String?
        for item in submenu.items {
            if item.identifier?.rawValue == "revision.copy.caption.branches" { image = "Branch" }
            if item.identifier?.rawValue == "revision.copy.caption.tags" { image = "Tag" }
            if item.identifier?.rawValue.hasPrefix("revision.copy.value.") == true, let image { setMenuImage(image, for: item) }
        }
    }

    @MainActor
    static func buttonColumnWidth(minimum: CGFloat, _ buttons: [NSButton]) -> CGFloat {
        max(minimum, buttons.map { ceil($0.intrinsicContentSize.width) }.max() ?? 0)
    }

    static func titledBox(_ title: String, _ content: NSView, inset: CGFloat = 8) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = title.isEmpty ? .noTitle : .atTop
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let holder = box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
                content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -inset),
                content.topAnchor.constraint(equalTo: holder.topAnchor, constant: inset),
                content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -inset)
            ])
        }
        return box
    }

    @MainActor
    static func autosizeColumns(_ table: NSTableView, _ identifiers: [String], includeHeader: Bool = false, maximumRows: Int = 1000) {
        guard let delegate = table.delegate, let rows = table.dataSource?.numberOfRows?(in: table) else { return }
        for identifier in identifiers {
            guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == identifier }) else { continue }
            var width: CGFloat = includeHeader ? column.headerCell.cellSize.width : 0
            for row in 0..<min(rows, maximumRows) {
                guard let view = delegate.tableView?(table, viewFor: column, row: row) else { continue }
                let field = (view as? NSTableCellView)?.textField ?? (view as? NSTextField)
                width = max(width, field?.intrinsicContentSize.width ?? view.fittingSize.width)
            }
            guard width > 0 else { continue }
            column.width = max(column.minWidth, ceil(width + 8))
        }
    }

    static func resourceImage(
        _ name: String,
        accessibilityDescription: String? = nil,
        size: NSSize = NSSize(width: 16, height: 16),
        isTemplate: Bool = false,
        adaptLightness: Bool = false
    ) -> NSImage? {
        let loadedImage: NSImage?
        if let url = Bundle.main.url(forResource: name, withExtension: "png") ?? Bundle.main.url(forResource: name, withExtension: "ico") {
            loadedImage = NSImage(contentsOf: url)
        } else if let encoded = embeddedGitExtensionsImages[name],
                  let data = Data(base64Encoded: encoded) {
            loadedImage = NSImage(data: data)
        } else {
            loadedImage = nil
        }
        guard var image = loadedImage else { return nil }
        if adaptLightness,
           NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
           let adapted = image.adaptingGitExtensionsLightness() {
            image = adapted
        }
        image.size = size
        image.isTemplate = isTemplate
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    @MainActor
    static func setMenuImage(_ name: String, for item: NSMenuItem, adaptLightness: Bool = false) {
        setMenuImage(resourceImage(name, accessibilityDescription: item.title, adaptLightness: adaptLightness), for: item)
    }

    @MainActor
    static func setMenuImage(_ image: NSImage?, for item: NSMenuItem) {
        item.image = image
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    @MainActor
    static func setMenuShortcut(_ id: String, for item: NSMenuItem) {
        guard let chord = ApplicationHotkeys.shared.chord(for: id) else { return }
        item.keyEquivalent = chord.key
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: chord.modifiers)
    }

    static func resourceButton(
        _ imageName: String,
        tooltip: String,
        width: CGFloat = 23,
        isTemplate: Bool = false,
        target: AnyObject?,
        action: Selector?
    ) -> NSButton {
        let button = NSButton(
            image: resourceImage(imageName, accessibilityDescription: tooltip, isTemplate: isTemplate) ?? NSImage(),
            target: target,
            action: action
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.controlSize = .small
        button.toolTip = tooltip
        button.setButtonType(.momentaryPushIn)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }

    static func symbolButton(
        _ symbol: String,
        tooltip: String,
        target: AnyObject?,
        action: Selector?
    ) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage(), target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.controlSize = .small
        button.toolTip = tooltip
        button.setButtonType(.momentaryPushIn)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 27),
            button.heightAnchor.constraint(equalToConstant: 23)
        ])
        return button
    }

    @MainActor static func textButton(
        _ title: String,
        symbol: String? = nil,
        tooltip: String? = nil,
        target: AnyObject?,
        action: Selector?
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.font = AppSettingsStore.shared.applicationFont(size: 11)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip ?? title)
            button.imagePosition = .imageLeading
        }
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 23).isActive = true
        return button
    }

    @MainActor static func popUp(_ title: String, width: CGFloat) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = AppSettingsStore.shared.applicationFont(size: 11)
        button.addItem(withTitle: title)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: width),
            button.heightAnchor.constraint(equalToConstant: 23)
        ])
        return button
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 6).isActive = true
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    static func toolbarBackground() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    @MainActor static func label(_ text: String, size: CGFloat = 11, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = AppSettingsStore.shared.applicationFont(size: size)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

private let embeddedGitExtensionsImages: [String: String] = [
    "Information": "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAMAAAAoLQ9TAAABTVBMVEUBDoACF5ACGpUDLLMDLbUDL7j///8DL7kCG5cDLLIABnUDLbUDL7gCGJIBD4IDMLoDKq8CHpsABXIDMLoCJ6sCIJ8ABXINOL0MNLcNNbgDMLoGIJwIIZwCJacCI6MGFYkUPb8VPsAABXIKI50LJJ0/ZthBaNkyV8k8YdElR70aPbggPbhmie1ni+02WcFWed0qUMVCZdBafuNihupkhulniu02YeM0YOAxW9g2YuE4YdoxVL1Ze91ylfRzlvRAcPVVd9kvVcIvWMs1YNgoTrkqUL4mSrQnSrA6Z+U+b/FEZsxHac9OcNbNzc3W1tb///80X9cjRawkRq0lSLE/b/EmSK4sUsBKbNIsVMNQcthXed9Ze+BfgecmSbIwWc3i4uLt7e0xWs9WeNxAYslCZMoxVL1lh+plh+vMzMw6aOY7X8gwWcs4Y9nu7u5TddoM/R2zAAAAQnRSTlMAAAAAAAAAGBkZGkhISktkZWhrmp2epbO0tLa4uLm6vMLCw8fH2trb293e4fHx8vLz8/Pz8/P09PT09Pz8/Pz9/f2EYWchAAAAzUlEQVQYGVXAwU7DIBgH8P/XD+lwa5pGVLOTNw8eTIzv/wa+xRITV0dKoUALw/N+JHFLoBA1O9Ei5XitlQWAdt+3QzXJ+giQLLsn/ekL+P777xyZ+a5/fks5bE1+9GuuzEp/XVJihDV9nOLGrAYGjrmuin+CTw1UV1+O6SEfnKudggCJ19FURRMBktAgTDQWTYMupZgAgRyJIFuSBKwZzEUs77ao7lx5/rWVebvSrEO3TmTGS2wE4Giz+wXBO+MIAoDNszjA5bgQQBK3/gGnO2f+J2zBzAAAAABJRU5ErkJggg==",
    "PullMerge": "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAACL0lEQVQ4y4WTPWhTURTHf+/lvaQftGgj6N6lKrrcQhzs0MGpCoqD4OgStAV1KS51dHBQB0mpSKEOCkoXEVtpQUQFC3khRUhSaKK2TbGI1vSleV9577ok7Wta8MCFc8/H/xzO+R+FhiQm89eBFPvlxsK14+P8TxKTeZmVUr51dl9WSpmYzMvWWCGE0tTVsGPVgszKH2aXF/lQKlIwq5h6CfmEZ0IIpZmYThpTQggVQAsDuHWQkU58JYopbX5u/0JBATiWThpzjYIS8NJJ43X/hLiwpwPXBbeuQ9BJxa1RcWpE/XhroWoDSAOUPQC2B7ar4tWjOB6oQQda0N50S2Ctf0JcbOgSQAtPf9OEmgWWD56v4dvdEFQ5pc8ObnZkf5ev3DkHRhgQDUjdv9xHdgOKm2C5EjuQeIHCekXn6sAJurvaeTAv4+W9ywgARfVqW7dHpwvogGV71CwH23Zx3DqW4wHwcP4bW7Gl9VCy3AHIjCQemeXS8NSnAieP6GjSpw2PiPTp69F5/jGHSX5tpXLrawsdtB0e5MaGUma5NPxiocDpozEAeg9HefU5Q2U1N/rdvrnUwpkmkXa30ASZzizT2xPjfeEHf7eL97oG3j0O7T8MEOxjYm5sKGWuFUdmFovknUtz8TNfXtKmBUAkVDUsUm215O6eT2WDwRkgapx9uhiaeKQlVAUC9SBUoA64jb8P1IB6+IgAHVAOamvn2gzDkGGbYRhSCKGmk8Yb4BCw8Q/PVAcRJy6jIQAAAABJRU5ErkJggg==",
    "PullRebase": "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAACBUlEQVQ4y72SvWtTURjGf+cm/QpNM1ikVUIHQWKXDhnuUukfkcnqokikMUsRujiWOhSEThUDjS7FoXQsKCgoOPiVWqcE0qg0H0q1xNx83M/c4+AtvaZWnHzg4ZyHc97nvJznFXhQs/k5YJXjSL2+duEeJ0D4DOT9qzFq1tHhmX648aCA8+zKEEBuPWf0GgT9oqxDUTvS7b42plbh/UzuERBghrZIculEA8sB0wYpXdraAWarhNHYgxAhYAiIyAxPgJJIkjpuYIFugKm32C8XOTtg0D88DvACGANGgVPAuT92YNjQMVzq+19ptToMj00wGLEQ17lzeEdmWAeiMsOmSJJQ1Gx+Ts3mJUC9Ca2Wg9ZoYjt9dAOnEUoANZuXXkqIJJcBAwgDKMDqciLG7HSMz3UwTDBNiWULyg3B7HSM5USMnoilRxS7o80vbBboA3TDRjcdXBFCN3Qa9e8EpcvCZgG7o833GGgAynZaXWlWP97MPH7OOFWsH3vohk7A7TLqVll7+gqtUkpvp9WVnvlRfhukqbu3G4Y2MXLxfJRywyI6EuTl7hcGwp+0D7eWIt4HPvQSkId1yuFmJ7y0MTBSK739FiShTvHuYJD+cKW0E17a8L3sAEWPux5/IR6PC4DJxa2Ums3LycWtFP8Dwjcgb4D6P9RIv1B87deA7l/oeKvrsQvs/wTO2+cHBSzr3wAAAABJRU5ErkJggg==",
    "PullFetch": "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABaUlEQVQ4y52Sv0sCYRzGP2epRCXUYmA01GINNhjc1NAsNFgNLQZt9Qe0ObVES1ttVi5CqNs1tYdQ4eQJWUsZNAldenpXvC2ed4fVWQ+8vO/zvu/zfH+8r0QXckY9Bnbox0lpe34XL8gZVZSFEJcde5SFEHJGFb/php3kSYf7N5t/hjzjug2MD+iYbv43AwP0toOP2Ov4+foRsAisWHu3W3nJZdA2Qe+4uQPLQLwvA2f3Gxq0dPuwodkN/iD9DjB1oUcURXmx7khyRhWHa1HKr/DQgHfDbvpYQGJuArLXG321327lJQCf2Xo72ytU8QN626Sld3pDb5v4PZooAaML+0p2PDKb3JSj3Dw30YxPxgNDLE2PkitV0eqPxZGZ06QzsgUf0KykEymt/ljMlarEwkEmgxALB3viSjqR+ikDX3fumRTuaqxGQxTuak5x08vAZXJwVR1I3PeRLJPusza9xN8ZMKjwuxL+hS+42LYAJVELiwAAAABJRU5ErkJggg==",
    "PullFetchAll": "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABxUlEQVQ4y42SP2hTURTGfy/mD0LRUoSAi4NDX1SKkJaCU8HNoIIVh4IN7SLRgB1Kt0Khi3TqVOmixiWDfR0iOjmWlkATaofmUmqGhipV8GH+3bz3WuJgb/J8bUo+ONx7D+f7zjn3HA0Pht8UloAEp/E6Oxl57nVqZxGXJ3S+2+2gq0F49laQnYxoXgGf655YntABKEkQZttKko7wux8q0D4Cy2n77aMuBVSgbYNsuPwX/53R1ONNoB/oAcjFVzTffwInfTcckFbbGg7cvrwBEFXkMytYzAgAzArUXX2bFdisfgYgZCbfr0+NxFtTcP/+wqjO1iF8M6FqN1sCX4tPTvWei69oagqJhVGda71BZgxBAJANh7q0WnYefE69/G7GENy5HiZoVUmtCW5eCeBvHiMtG3/zmKeDH9yZe1R2AF8+OZysHBRX07kS94ciXKiXSWcFA+EQfSEYCIdIZ4U7ac27SLWd2dh45aC4amyXuBftJyD/YOT3eKBfwsjvUd7fzXRsQakqkY+FH7y4ewv5+5BXXwTl/d1MYe7hWDeLVNuZjY3fmP/E4jqPLPNnZnt65CXwy1t2xz1QIidjrZ1H7CRAt0SFv6GSxo+5IPzDAAAAAElFTkSuQmCC",
    "PullFetchPruneAll": "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAABu0lEQVQ4y42QMWgTURjHfzmOBikU6ZAnOlgRyqVgQRsIuDg4iRCFOnZplxLJXBCHUhelk1OlSxUEg8jREFfp5BJoMhTKXUlxOUq9Dm2943yXC20c6uudZ1ryh4/37uP7fv97/wwpFdesFaDM/3rXmMs/Tzcz/RZXZw32OvHQjSzMv7dpzOUzaYCWuJdXZw0A9jqwcxxXEpaWnvxQg2EEnW7cD6MBAWowikCGcT+6cnZuwZdrQtxS/ZzrFv4BRH8BYRdk4rfDLrx6+biZXO6XAW/rNgBHPkgZ15EPd08DAJ6++Lydc91CznULAJlk+svTBk0XfvwCGZ6eg18/u95MOyuABpSXpw1uXh1iwbQZ4mw5kNF5XSat+9v7sGDa3L8t0KXPx+82d0Y19N4JshOh9074tPFzKuH8QLkDaK1KseI57Vq16fCkOIEufaoNm0mRZTQLkyJLtWEnTYN0iIG1WJrxnHbN3HJ4dG8cXfqYrV1KxghmaxfPadcufIKiKshXa5/Kwwnkocubbzae065Zi6UZBtRwfqm+Xlyzevml+jowBgwDHAixeSDE5kAQIKcWlS4C6H0AQTqoy/QHNArH+LF8X5UAAAAASUVORK5CYII="
]

private extension NSImage {
    func adaptingGitExtensionsLightness() -> NSImage? {
        var proposedRect = NSRect(origin: .zero, size: size)
        guard let source = cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else { return nil }
        let width = source.width
        let height = source.height
        let bytesPerRow = width * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var foreground = (red: CGFloat(1), green: CGFloat(1), blue: CGFloat(1))
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let color = NSColor.labelColor.usingColorSpace(.deviceRGB) {
                foreground = (color.redComponent, color.greenComponent, color.blueComponent)
            }
        }
        let textLightness = Self.rgbToHSL(foreground.red, foreground.green, foreground.blue).lightness
        let backgroundLightness: CGFloat = 0.20

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                let alpha = CGFloat(pixels[offset + 3]) / 255
                guard alpha > 0 else { continue }
                let red = min(1, CGFloat(pixels[offset]) / 255 / alpha)
                let green = min(1, CGFloat(pixels[offset + 1]) / 255 / alpha)
                let blue = min(1, CGFloat(pixels[offset + 2]) / 255 / alpha)
                var hsl = Self.rgbToHSL(red, green, blue)
                let gamma = Self.perceivedGamma(red, green, blue)
                let perceivedLightness = Self.gammaTransform(hsl.lightness, gamma: gamma)
                hsl.saturation = perceivedLightness > 0.1
                    ? hsl.saturation
                    : hsl.saturation * perceivedLightness / 0.1
                let transformed = textLightness + perceivedLightness * (backgroundLightness - textLightness)
                hsl.lightness = Self.gammaTransform(transformed, gamma: 1 / gamma)
                let rgb = Self.hslToRGB(hsl)
                pixels[offset] = UInt8((rgb.red * alpha * 255).rounded().clamped(to: 0...255))
                pixels[offset + 1] = UInt8((rgb.green * alpha * 255).rounded().clamped(to: 0...255))
                pixels[offset + 2] = UInt8((rgb.blue * alpha * 255).rounded().clamped(to: 0...255))
            }
        }
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: size)
    }

    private struct HSL {
        var hue: CGFloat
        var saturation: CGFloat
        var lightness: CGFloat
    }

    private static func rgbToHSL(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> HSL {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        guard delta > 0 else { return HSL(hue: 0, saturation: 0, lightness: lightness) }
        let saturation = lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
        let hue: CGFloat
        if maximum == red {
            hue = ((green - blue) / delta + (green < blue ? 6 : 0)) / 6
        } else if maximum == green {
            hue = ((blue - red) / delta + 2) / 6
        } else {
            hue = ((red - green) / delta + 4) / 6
        }
        return HSL(hue: hue, saturation: saturation, lightness: lightness)
    }

    private static func hslToRGB(_ hsl: HSL) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        guard hsl.saturation > 0 else { return (hsl.lightness, hsl.lightness, hsl.lightness) }
        let q = hsl.lightness < 0.5
            ? hsl.lightness * (1 + hsl.saturation)
            : hsl.lightness + hsl.saturation - hsl.lightness * hsl.saturation
        let p = 2 * hsl.lightness - q
        func channel(_ value: CGFloat) -> CGFloat {
            var value = value
            if value < 0 { value += 1 }
            if value > 1 { value -= 1 }
            if value < 1 / 6 { return p + (q - p) * 6 * value }
            if value < 1 / 2 { return q }
            if value < 2 / 3 { return p + (q - p) * (2 / 3 - value) * 6 }
            return p
        }
        return (channel(hsl.hue + 1 / 3), channel(hsl.hue), channel(hsl.hue - 1 / 3))
    }

    private static func perceivedGamma(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGFloat {
        let denominator = red * 0.8 + green * 1.75 + blue * 0.45
        return denominator > 0 ? (red + green + blue) / denominator : 1
    }

    private static func gammaTransform(_ lightness: CGFloat, gamma: CGFloat) -> CGFloat {
        guard gamma > 0 else { return lightness }
        let threshold = gamma / (gamma + 1)
        return lightness < threshold ? lightness / gamma : 1 + gamma * (lightness - 1)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

final class GitExtensionsSelectionRowView: NSTableRowView {
    var repositoryBackgroundColor: NSColor?
    override func drawBackground(in dirtyRect: NSRect) {
        guard let repositoryBackgroundColor else { super.drawBackground(in: dirtyRect); return }
        repositoryBackgroundColor.setFill()
        dirtyRect.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let color = isEmphasized
            ? ApplicationColors.color("Selection", fallback: NSColor.systemBlue.withAlphaComponent(0.62))
            : ApplicationColors.color("InactiveSelectionHighlight", fallback: NSColor.unemphasizedSelectedContentBackgroundColor)
        color.setFill()
        dirtyRect.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }

    override var isOpaque: Bool { false }
}

class LeadingImageButton: NSButton {
    override class var cellClass: AnyClass? {
        get { LeadingImageButtonCell.self }
        set {}
    }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard let cell = cell as? LeadingImageButtonCell else { return size }
        return NSSize(width: max(size.width, cell.cellSize.width), height: size.height)
    }
}

final class LeadingImageButtonCell: NSButtonCell {
    static let imageInset: CGFloat = 8
    static let imageSpacing: CGFloat = 6

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let image else { return super.imageRect(forBounds: rect) }
        return NSRect(x: rect.minX + Self.imageInset, y: (rect.midY - image.size.height / 2).rounded(),
                      width: image.size.width, height: image.size.height)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        var frame = super.titleRect(forBounds: rect)
        guard image != nil else { return frame }
        let width = min(ceil(attributedTitle.size().width), rect.width)
        frame.origin.x = (rect.midX - width / 2).rounded()
        frame.size.width = width
        return frame
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard image != nil else { return super.drawTitle(title, withFrame: frame, in: controlView) }
        return super.drawTitle(title, withFrame: titleRect(forBounds: controlView.bounds), in: controlView)
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        super.drawImage(image, withFrame: imageRect(forBounds: controlView.bounds), in: controlView)
    }

    override var cellSize: NSSize { fitted(super.cellSize) }

    override func cellSize(forBounds rect: NSRect) -> NSSize { fitted(super.cellSize(forBounds: rect)) }

    private func fitted(_ size: NSSize) -> NSSize {
        guard let image else { return size }
        return NSSize(width: max(size.width, ceil(attributedTitle.size().width) + 2 * (Self.imageInset + image.size.width + Self.imageSpacing)), height: size.height)
    }
}
