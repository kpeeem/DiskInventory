import AppKit
import InventoryCore
import SwiftUI

struct MapPlaceholder: Equatable {
    var title: String
    var symbol: String
    var detail = ""
    var action: String?
    var busy = false
}

private struct PlaceholderView: View {
    let placeholder: MapPlaceholder
    let perform: () -> Void

    var body: some View {
        Group {
            if placeholder.busy {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(placeholder.title).font(.title3.weight(.semibold))
                    if !placeholder.detail.isEmpty {
                        Text(placeholder.detail)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
            } else {
                ContentUnavailableView {
                    Label(placeholder.title, systemImage: placeholder.symbol)
                } description: {
                    if !placeholder.detail.isEmpty { Text(placeholder.detail) }
                } actions: {
                    if let action = placeholder.action { Button(action, action: perform) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

@MainActor private final class TileElement: NSAccessibilityElement {
    let id: Int
    let press: (Int) -> Void

    init(id: Int, press: @escaping (Int) -> Void) {
        self.id = id
        self.press = press
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        press(id)
        return true
    }
}

@MainActor final class TreemapView: NSView {
    var choose: ((Int, Bool) -> Void)?
    var zoomAggregate: ((Int, Int?) -> Void)?
    var hover: ((Int?) -> Void)?
    var context: ((Int) -> NSMenu?)?
    var quickLook: (() -> Void)?
    var zoomOutRequest: (() -> Void)?
    var placeholderAction: (() -> Void)?
    var acceptsTileActions = false
    private var tracking: NSTrackingArea?
    private var tiles: [MapTile] = []
    var hasTiles: Bool { !tiles.isEmpty }
    private var colors: [CGColor] = []
    func usesAnySwatch(from swatches: [NSColor]) -> Bool {
        let expected = swatches.map(\.cgColor)
        return colors.contains { expected.contains($0) }
    }

    private var labelColors: [NSColor] = []
    var mapAppearance = MapAppearance() {
        didSet { if oldValue != mapAppearance { needsDisplay = true } }
    }
    private var labels: [Int: String] = [:]
    private var headers: [Int: String] = [:]
    private var nodeKinds: [Int32] = []
    private var emphasized: [Bool] = []
    private var snapshot: ScanSummary?
    private var options = ViewOptions()
    private var tileSize: CGSize = .zero
    private var selectionFrames: [Int: CGRect] = [:]
    private var hoverID: Int?
    private let highlight = SelectionHighlight()
    private let overlay = NSHostingView(rootView: PlaceholderView(placeholder: MapPlaceholder(title: "", symbol: ""), perform: {}))
    var selection: Int? { didSet { if oldValue != selection { updateHighlight() } } }
    var resized: (() -> Void)?
    var placeholder = MapPlaceholder(title: "No Scan", symbol: "square.grid.3x3.square", detail: "Open a folder or volume to scan") {
        didSet { if oldValue != placeholder { updatePlaceholder() } }
    }
    var highlightKind: Int32? { didSet { if oldValue != highlightKind { updateEmphasis() } } }
    var highlightNodes: Set<Int>? { didSet { if oldValue != highlightNodes { updateEmphasis() } } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { acceptsTileActions }
    override var canBecomeKeyView: Bool { acceptsTileActions }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleAxesIndependently
        focusRingType = .exterior
        highlight.frame = bounds
        highlight.autoresizingMask = [.width, .height]
        highlight.wantsLayer = true
        addSubview(highlight)
        overlay.sizingOptions = []
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updatePlaceholder()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Treemap")
    }

    required init?(coder: NSCoder) { nil }

    func show(_ tiles: [MapTile], snapshot: ScanSummary, colors: [NSColor], size: CGSize, options: ViewOptions, animate: Bool) {
        self.tiles = tiles
        self.snapshot = snapshot
        self.options = options
        acceptsTileActions = true
        tileSize = size
        recolor(colors)
        labels.removeAll(keepingCapacity: true)
        headers.removeAll(keepingCapacity: true)
        nodeKinds = tiles.map { $0.id >= 0 ? snapshot.nodes[$0.id].kind : -1 }
        for tile in tiles {
            if tile.header > 0, tile.id >= 0 {
                headers[tile.id] = snapshot.nodes[tile.id].name + "  " + formatSize(snapshot.size(of: tile.id, options: options))
            } else if tile.rect.width > 84, tile.rect.height > 22, !tile.container {
                labels[tile.id] = tile.id >= 0 ? snapshot.nodes[tile.id].name : (tile.id == -1 ? "Free Space" : "Other Space")
            }
        }
        selectionFrames.removeAll(keepingCapacity: true)
        for tile in tiles where !tile.aggregate {
            selectionFrames[tile.id] = tile.rect
        }
        hoverID = nil
        updateEmphasis()
        updateHighlight()
        updatePlaceholder()
        if animate {
            let fade = CATransition()
            fade.duration = 0.17
            fade.type = .fade
            layer?.add(fade, forKey: "zoom")
        }
        needsDisplay = true
    }

    func recolor(_ colors: [NSColor]) {
        self.colors = colors.map { $0.cgColor }
        labelColors = colors.map(TreemapPalette.foreground)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        highlight.needsDisplay = true
    }

    func clear() {
        acceptsTileActions = false
        tiles = []
        nodeKinds = []
        emphasized = []
        labels = [:]
        headers = [:]
        selectionFrames = [:]
        hoverID = nil
        updateHighlight()
        updatePlaceholder()
        needsDisplay = true
    }

    private func updatePlaceholder() {
        overlay.isHidden = !tiles.isEmpty
        overlay.rootView = PlaceholderView(placeholder: placeholder) { [weak self] in self?.placeholderAction?() }
    }

    private func updateEmphasis() {
        defer { needsDisplay = true }
        guard let snapshot, !tiles.isEmpty, highlightKind != nil || highlightNodes != nil else {
            emphasized = []
            return
        }
        emphasized = tiles.indices.map { index in
            let tile = tiles[index]
            guard !tile.aggregate, tile.id >= 0, snapshot.nodes.indices.contains(tile.id) else { return false }
            if let kind = highlightKind { return !tile.container && nodeKinds[index] == kind }
            guard let nodes = highlightNodes else { return true }
            var current = tile.id
            while current >= 0 {
                if nodes.contains(current) { return true }
                current = Int(snapshot.nodes[current].parent)
            }
            return false
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previous = frame.size
        super.setFrameSize(newSize)
        if newSize != previous {
            updateHighlight()
            if tiles.isEmpty { needsDisplay = true }
            resized?()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private var scale: CGAffineTransform {
        CGAffineTransform(scaleX: bounds.width / tileSize.width, y: bounds.height / tileSize.height)
    }

    private func tile(at event: NSEvent) -> MapTile? {
        guard acceptsTileActions, bounds.width > 0, bounds.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let original = CGPoint(x: point.x * tileSize.width / bounds.width, y: point.y * tileSize.height / bounds.height)
        return tiles.last(where: { $0.rect.contains(original) })
    }

    override func mouseMoved(with event: NSEvent) {
        let tile = tile(at: event)
        let id = tile?.aggregate == false ? tile?.id : nil
        guard id != hoverID else { return }
        hoverID = id
        updateHighlight()
        hover?(id)
    }

    override func mouseExited(with event: NSEvent) {
        hoverID = nil
        updateHighlight()
        hover?(nil)
    }

    private func updateHighlight() {
        guard tileSize.width > 0, tileSize.height > 0 else {
            highlight.rectangle = nil
            highlight.hover = nil
            return
        }
        highlight.rectangle = selection.flatMap { selectionFrames[$0] }.map { $0.applying(scale).insetBy(dx: 0.35, dy: 0.35) }
        highlight.hover = hoverID.flatMap { $0 == selection ? nil : selectionFrames[$0] }.map { $0.applying(scale).insetBy(dx: 0.35, dy: 0.35) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tile = tile(at: event) else { return }
        window?.makeFirstResponder(self)
        if tile.aggregate {
            if event.clickCount == 2, let snapshot {
                let visible = Set(tiles.lazy.filter { !$0.aggregate }.map(\.id))
                var child = snapshot.nodes[tile.id].firstChild
                while child >= 0, visible.contains(Int(child)) { child = snapshot.nodes[Int(child)].nextSibling }
                zoomAggregate?(tile.id, child >= 0 ? Int(child) : nil)
            }
        } else {
            choose?(tile.id, event.clickCount == 2)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tile = tile(at: event), !tile.aggregate else { return nil }
        return context?(tile.id)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let arrows: Set<UInt16> = [123, 124, 125, 126]
        if event.keyCode == 49, modifiers.isEmpty {
            quickLook?()
        } else if (event.keyCode == 36 || event.keyCode == 76), modifiers.isEmpty, let selection {
            choose?(selection, true)
        } else if event.keyCode == 126, modifiers == .command {
            zoomOutRequest?()
        } else if event.keyCode == 125, modifiers == .command, let selection {
            choose?(selection, true)
        } else if arrows.contains(event.keyCode), modifiers.isEmpty, acceptsTileActions {
            move(event.keyCode)
        } else {
            super.keyDown(with: event)
        }
    }

    private func move(_ key: UInt16) {
        let candidates = tiles.filter { !$0.aggregate && $0.id >= 0 }
        guard !candidates.isEmpty else { return }
        guard let current = selection.flatMap({ selectionFrames[$0] }) else {
            let files = candidates.filter { !$0.container }
            let largest = (files.isEmpty ? candidates : files).max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
            if let largest { choose?(largest.id, false) }
            return
        }
        let origin = CGPoint(x: current.midX, y: current.midY)
        var best: (score: CGFloat, id: Int)?
        for tile in candidates where tile.id != selection && !tile.rect.contains(origin) {
            let dx = tile.rect.midX - origin.x
            let dy = tile.rect.midY - origin.y
            let primary: CGFloat
            let secondary: CGFloat
            switch key {
            case 123: (primary, secondary) = (-dx, abs(dy))
            case 124: (primary, secondary) = (dx, abs(dy))
            case 125: (primary, secondary) = (dy, abs(dx))
            default: (primary, secondary) = (-dy, abs(dx))
            }
            guard primary > 0.5 else { continue }
            let score = primary + secondary * 2
            if best.map({ score < $0.score }) ?? true { best = (score, tile.id) }
        }
        if let best { choose?(best.id, false) }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let snapshot, !tiles.isEmpty, tileSize.width > 0, tileSize.height > 0 else { return [] }
        let total = max(1, snapshot.size(of: tiles.first.map { Int(snapshot.nodes[max(0, $0.id)].parent) } ?? 0, options: options))
        let largest = tiles.filter { !$0.aggregate && $0.id >= 0 }
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            .prefix(40)
        return largest.map { tile in
            let element = TileElement(id: tile.id) { [weak self] id in self?.choose?(id, false) }
            let size = snapshot.size(of: tile.id, options: options)
            let share = Double(size) / Double(total)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel("\(snapshot.nodes[tile.id].name), \(formatSize(size)), \(share.formatted(.percent.precision(.fractionLength(0))))")
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(NSAccessibility.screenRect(fromView: self, rect: tile.rect.applying(scale)))
            return element
        }
    }

    private func tone(_ fraction: CGFloat) -> CGColor {
        guard let base = NSColor.controlBackgroundColor.usingColorSpace(.sRGB),
              let ink = NSColor.labelColor.usingColorSpace(.sRGB),
              let mixed = base.blended(withFraction: fraction, of: ink.withAlphaComponent(1)) else { return NSColor.gridColor.cgColor }
        return mixed.cgColor
    }

    private func hatch(_ frame: CGRect, color: CGColor, in context: CGContext) {
        context.saveGState()
        context.clip(to: frame)
        context.setStrokeColor(color)
        context.setLineWidth(0.6)
        var x = frame.minX - frame.height
        while x < frame.maxX {
            context.move(to: CGPoint(x: x, y: frame.maxY))
            context.addLine(to: CGPoint(x: x + frame.height, y: frame.minY))
            x += 5
        }
        context.strokePath()
        context.restoreGState()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        guard !tiles.isEmpty, tileSize.width > 0, tileSize.height > 0, let graphics = NSGraphicsContext.current else { return }
        let context = graphics.cgContext
        graphics.saveGraphicsState()
        context.scaleBy(x: bounds.width / tileSize.width, y: bounds.height / tileSize.height)
        let group = tone(0.14)
        let headerFill = tone(0.2)
        let aggregate = tone(0.06)
        let stripes = tone(0.18)
        let space = tone(0.3)
        let line = NSColor.black.withAlphaComponent(0.17).cgColor
        let folderBorder = NSColor.windowBackgroundColor.cgColor
        let dim = NSColor.controlBackgroundColor.withAlphaComponent(0.76).cgColor
        let dimming = emphasized.count == tiles.count
        for (index, tile) in tiles.enumerated() {
            let kind = Int(nodeKinds[index])
            let frame = tile.rect.insetBy(dx: 0.35, dy: 0.35)
            guard frame.width > 0, frame.height > 0 else { continue }
            context.setFillColor(tile.aggregate ? aggregate : tile.container ? group : kind < 0 ? space : colors[kind])
            context.fill(frame)
            if tile.aggregate { hatch(frame, color: stripes, in: context) }
            if tile.header > 0 {
                context.setFillColor(headerFill)
                context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: tile.header - 0.35))
            }
            if tile.container && mapAppearance.folderBorders {
                context.setStrokeColor(folderBorder)
                context.setLineWidth(1.5)
                context.stroke(frame.insetBy(dx: 0.75, dy: 0.75))
            } else if !tile.container && !tile.aggregate {
                context.setStrokeColor(line)
                context.setLineWidth(0.65)
                context.stroke(frame.insetBy(dx: 0.4, dy: 0.4))
            }
            let faded = dimming && !emphasized[index]
            if faded {
                context.setFillColor(dim)
                context.fill(frame)
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            if tile.header > 0, let title = headers[tile.id], frame.width >= 40 {
                NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: faded ? NSColor.tertiaryLabelColor : NSColor.labelColor,
                    .paragraphStyle: style
                ]).draw(in: CGRect(x: frame.minX + 6, y: frame.minY + 1, width: frame.width - 12, height: 14))
            } else if mapAppearance.labels, frame.width >= 70, frame.height >= 20, !tile.container,
                      let title = tile.aggregate ? "Small items" : labels[tile.id] {
                let color: NSColor = faded ? .tertiaryLabelColor
                    : tile.aggregate ? .secondaryLabelColor : kind < 0 ? .controlBackgroundColor : labelColors[kind]
                NSAttributedString(string: title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: color,
                    .paragraphStyle: style
                ]).draw(in: CGRect(x: frame.minX + 6, y: frame.minY + 4, width: frame.width - 12, height: 15))
            }
        }
        graphics.restoreGraphicsState()
    }
}

@MainActor private final class SelectionHighlight: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var rectangle: CGRect? {
        didSet { invalidate(oldValue, rectangle) }
    }

    var hover: CGRect? {
        didSet { invalidate(oldValue, hover) }
    }

    private func invalidate(_ old: CGRect?, _ new: CGRect?) {
        for rect in [old, new].compactMap({ $0 }) { setNeedsDisplay(rect.insetBy(dx: -4, dy: -4)) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        if let hover, hover.width > 4, hover.height > 4 {
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1.5)
            context.stroke(hover.insetBy(dx: 0.75, dy: 0.75))
        }
        guard let rectangle, rectangle.width > 4, rectangle.height > 4 else { return }
        let frame = rectangle.insetBy(dx: 1.5, dy: 1.5)
        context.setStrokeColor(NSColor.windowBackgroundColor.cgColor)
        context.setLineWidth(5)
        context.stroke(frame)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(3)
        context.stroke(frame)
    }
}
