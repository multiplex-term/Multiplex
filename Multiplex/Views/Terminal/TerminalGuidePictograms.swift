import UIKit

/// Decorative field-manual figures, authored in one 96 × 64 coordinate
/// space and scaled without changing the one-and-a-half-point pen weight.
@MainActor
final class TerminalGuidePictogramView: UIView {
    private enum Design {
        static let size = CGSize(width: 96, height: 64)
        static let strokeWidth: CGFloat = 1.5
        static let dash: [CGFloat] = [2, 3]
    }

    private let entryID: String
    private var drawingScale: CGFloat = 1

    init(entryID: String) {
        self.entryID = entryID
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, GlassAppearanceTrait.self]
        ) { (view: TerminalGuidePictogramView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              bounds.width > 0,
              bounds.height > 0
        else { return }

        drawingScale = min(
            bounds.width / Design.size.width,
            bounds.height / Design.size.height
        )
        let drawnSize = CGSize(
            width: Design.size.width * drawingScale,
            height: Design.size.height * drawingScale
        )
        context.saveGState()
        context.translateBy(
            x: (bounds.width - drawnSize.width) / 2,
            y: (bounds.height - drawnSize.height) / 2
        )
        context.scaleBy(x: drawingScale, y: drawingScale)

        switch entryID {
        case "doubletap": drawDoubleTap()
        case "longpress": drawLongPress()
        case "rightclick": drawRightClick()
        case "pan": drawPan()
        case "edgeswipe": drawEdgeSwipe()
        case "link": drawLink()
        case "path": drawPath()
        case "kbdlock": drawKeyboardLock()
        case "dictate": drawDictation()
        case "shiftreturn": drawShiftReturn()
        case "shortcutkey": drawShortcutKey()
        case "keycommands": drawKeyCommands()
        case "resize": drawResize()
        case "panemenu": drawPaneMenu()
        case "paste": drawPastePermission()
        default: break
        }
        context.restoreGState()
    }

    private func drawDoubleTap() {
        drawPaneBackdrop()
        fillCircle(center: CGPoint(x: 27, y: 32), radius: 3.4, color: UIKitChassis.signal)
        strokeCircle(
            center: CGPoint(x: 27, y: 32),
            radius: 9,
            color: UIKitChassis.signal
        )
        strokeCircle(
            center: CGPoint(x: 27, y: 32),
            radius: 15,
            color: UIKitChassis.signal2.withAlphaComponent(0.5),
            dashed: true
        )
        drawSelectionBlock()
    }

    private func drawLongPress() {
        drawPaneBackdrop()
        drawMonoText(
            "0.5 s",
            at: CGPoint(x: 10, y: 24),
            size: 6.5,
            color: UIKitChassis.signal3
        )
        let center = CGPoint(x: 28, y: 36)
        fillCircle(center: center, radius: 3.4, color: UIKitChassis.signal)
        let arc = UIBezierPath(
            arcCenter: center,
            radius: 11,
            startAngle: -.pi / 2,
            endAngle: .pi,
            clockwise: true
        )
        stroke(arc, color: UIKitChassis.signal)
        drawSelectionBlock()
    }

    private func drawRightClick() {
        drawPaneBackdrop()
        let mouseRect = CGRect(x: 36, y: 16, width: 24, height: 38)
        let mouse = UIBezierPath(roundedRect: mouseRect, cornerRadius: 12)
        if let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            mouse.addClip()
            fill(
                UIBezierPath(rect: CGRect(x: 48, y: 16, width: 12, height: 12)),
                color: UIKitChassis.signal.withAlphaComponent(0.22)
            )
            context.restoreGState()
        }
        stroke(mouse, color: UIKitChassis.signal)

        let controls = UIBezierPath()
        controls.move(to: CGPoint(x: 48, y: 16))
        controls.addLine(to: CGPoint(x: 48, y: 28))
        controls.move(to: CGPoint(x: 36, y: 28))
        controls.addLine(to: CGPoint(x: 60, y: 28))
        stroke(controls, color: UIKitChassis.signal)

        let ticks = UIBezierPath()
        ticks.move(to: CGPoint(x: 63, y: 20))
        ticks.addLine(to: CGPoint(x: 68, y: 18))
        ticks.move(to: CGPoint(x: 64, y: 24))
        ticks.addLine(to: CGPoint(x: 70, y: 24))
        stroke(ticks, color: UIKitChassis.signal2)
    }

    private func drawPan() {
        drawPaneBackdrop()
        for (start, end, y) in [(12.0, 55.0, 36.0),
                                (12.0, 61.0, 43.0),
                                (12.0, 47.0, 50.0)] {
            let row = UIBezierPath()
            row.move(to: CGPoint(x: start, y: y))
            row.addLine(to: CGPoint(x: end, y: y))
            stroke(
                row,
                color: UIKitChassis.signal2.withAlphaComponent(0.5),
                dashed: true
            )
        }
        drawArrow(
            from: CGPoint(x: 82, y: 18),
            to: CGPoint(x: 82, y: 49),
            color: UIKitChassis.signal,
            startHead: true,
            endHead: true
        )
    }

    private func drawEdgeSwipe() {
        drawPaneBackdrop()
        let edge = UIBezierPath()
        edge.move(to: CGPoint(x: 7, y: 8))
        edge.addLine(to: CGPoint(x: 7, y: 56))
        stroke(edge, color: UIKitChassis.signal, width: 2.5)
        strokeCircle(
            center: CGPoint(x: 10, y: 32),
            radius: 6,
            color: UIKitChassis.signal2.withAlphaComponent(0.5),
            dashed: true
        )
        drawArrow(
            from: CGPoint(x: 10, y: 32),
            to: CGPoint(x: 54, y: 32),
            color: UIKitChassis.signal,
            endHead: true
        )
    }

    private func drawLink() {
        drawPressedText("https://host:5173")
    }

    private func drawPath() {
        drawPressedText("src/app.swift:120")
    }

    private func drawKeyboardLock() {
        let slab = UIBezierPath(
            roundedRect: CGRect(x: 12, y: 35, width: 72, height: 22),
            cornerRadius: 5
        )
        stroke(slab, color: UIKitChassis.signal2)
        for y in [43.0, 50.0] {
            let keys = UIBezierPath()
            keys.move(to: CGPoint(x: 19, y: y))
            keys.addLine(to: CGPoint(x: 77, y: y))
            stroke(
                keys,
                color: UIKitChassis.signal2.withAlphaComponent(0.5),
                dashed: true
            )
        }

        let body = UIBezierPath(
            roundedRect: CGRect(x: 41, y: 22, width: 14, height: 11),
            cornerRadius: 2
        )
        stroke(body, color: UIKitChassis.signal)
        let shackle = UIBezierPath(
            arcCenter: CGPoint(x: 48, y: 22),
            radius: 5,
            startAngle: .pi,
            endAngle: 0,
            clockwise: true
        )
        stroke(shackle, color: UIKitChassis.signal)
    }

    private func drawDictation() {
        fillCircle(
            center: CGPoint(x: 14, y: 13),
            radius: 3,
            color: TallyPalette.tally
        )
        drawMonoText(
            "LIVE",
            at: CGPoint(x: 20, y: 9),
            size: 6.5,
            color: TallyPalette.tally
        )

        let capsule = UIBezierPath(
            roundedRect: CGRect(x: 29, y: 20, width: 12, height: 22),
            cornerRadius: 6
        )
        stroke(capsule, color: UIKitChassis.signal)
        let stand = UIBezierPath()
        stand.addArc(
            withCenter: CGPoint(x: 35, y: 34),
            radius: 11,
            startAngle: 0,
            endAngle: .pi,
            clockwise: true
        )
        stand.move(to: CGPoint(x: 35, y: 45))
        stand.addLine(to: CGPoint(x: 35, y: 51))
        stand.move(to: CGPoint(x: 29, y: 51))
        stand.addLine(to: CGPoint(x: 41, y: 51))
        stroke(stand, color: UIKitChassis.signal)

        let levels = UIBezierPath()
        levels.move(to: CGPoint(x: 52, y: 31))
        levels.addLine(to: CGPoint(x: 52, y: 39))
        levels.move(to: CGPoint(x: 60, y: 27))
        levels.addLine(to: CGPoint(x: 60, y: 43))
        levels.move(to: CGPoint(x: 68, y: 33))
        levels.addLine(to: CGPoint(x: 68, y: 37))
        stroke(levels, color: UIKitChassis.signal2, width: 2)
    }

    private func drawShiftReturn() {
        drawKeycap(CGRect(x: 13, y: 21, width: 28, height: 24), label: "⇧")
        drawMonoText(
            "+",
            centeredIn: CGRect(x: 43, y: 21, width: 10, height: 24),
            size: 9,
            color: UIKitChassis.signal2
        )
        drawKeycap(CGRect(x: 55, y: 21, width: 28, height: 24), label: "⏎")
    }

    private func drawShortcutKey() {
        drawKeycap(
            CGRect(x: 7, y: 23, width: 31, height: 18),
            label: "TMUX",
            labelSize: 6.5
        )
        drawArrow(
            from: CGPoint(x: 41, y: 32),
            to: CGPoint(x: 49, y: 32),
            color: UIKitChassis.signal2,
            endHead: true
        )
        let panel = UIBezierPath(roundedRect: CGRect(x: 52, y: 8, width: 36, height: 48), cornerRadius: 2)
        stroke(panel, color: UIKitChassis.signal)
        for y in [16.0, 24.0, 32.0, 40.0, 48.0] {
            let row = UIBezierPath()
            row.move(to: CGPoint(x: 58, y: y))
            row.addLine(to: CGPoint(x: 82, y: y))
            stroke(
                row,
                color: UIKitChassis.signal2.withAlphaComponent(0.5),
                dashed: true
            )
        }
    }

    /// A held CTRL key (the long-press arc, "0.3 s") raising the two-column
    /// Key Commands grid.
    private func drawKeyCommands() {
        drawKeycap(
            CGRect(x: 7, y: 26, width: 30, height: 18),
            label: "CTRL",
            labelSize: 6.5
        )
        drawMonoText(
            "0.3 s",
            at: CGPoint(x: 8, y: 6),
            size: 6.5,
            color: UIKitChassis.signal3
        )
        let center = CGPoint(x: 22, y: 35)
        let arc = UIBezierPath(
            arcCenter: center,
            radius: 15,
            startAngle: -.pi / 2,
            endAngle: .pi,
            clockwise: true
        )
        stroke(arc, color: UIKitChassis.signal)
        drawArrow(
            from: CGPoint(x: 41, y: 35),
            to: CGPoint(x: 49, y: 35),
            color: UIKitChassis.signal2,
            endHead: true
        )
        let panel = UIBezierPath(roundedRect: CGRect(x: 52, y: 12, width: 38, height: 44), cornerRadius: 2)
        stroke(panel, color: UIKitChassis.signal)
        for (row, label) in [(0, "⇧⏎"), (1, "⌃C"), (2, "⌥⌫")] {
            let y = 18 + CGFloat(row) * 13
            drawKeycap(
                CGRect(x: 56, y: y, width: 14, height: 9),
                label: label,
                labelSize: 5
            )
            let line = UIBezierPath()
            line.move(to: CGPoint(x: 73, y: y + 4.5))
            line.addLine(to: CGPoint(x: 86, y: y + 4.5))
            stroke(
                line,
                color: UIKitChassis.signal2.withAlphaComponent(0.5),
                dashed: true
            )
        }
    }

    private func drawResize() {
        let frame = UIBezierPath(roundedRect: CGRect(x: 6, y: 8, width: 84, height: 48), cornerRadius: 3)
        stroke(frame, color: UIKitChassis.signal2)
        let border = UIBezierPath()
        border.move(to: CGPoint(x: 48, y: 8))
        border.addLine(to: CGPoint(x: 48, y: 56))
        stroke(border, color: UIKitChassis.signal, width: 2.5)
        strokeCircle(
            center: CGPoint(x: 48, y: 32),
            radius: 9,
            color: UIKitChassis.signal2.withAlphaComponent(0.5),
            dashed: true
        )
        drawArrow(
            from: CGPoint(x: 39, y: 32),
            to: CGPoint(x: 20, y: 32),
            color: UIKitChassis.signal,
            endHead: true
        )
        drawArrow(
            from: CGPoint(x: 57, y: 32),
            to: CGPoint(x: 76, y: 32),
            color: UIKitChassis.signal,
            endHead: true
        )
    }

    private func drawPaneMenu() {
        drawPaneBackdrop()
        let center = CGPoint(x: 27, y: 35)
        fillCircle(center: center, radius: 3.4, color: UIKitChassis.signal)
        let tether = UIBezierPath()
        tether.move(to: center)
        tether.addLine(to: CGPoint(x: 35, y: 31))
        stroke(tether, color: UIKitChassis.signal)
        let menu = UIBezierPath(roundedRect: CGRect(x: 35, y: 19, width: 38, height: 30), cornerRadius: 2)
        fill(menu, color: UIKitChassis.screen)
        stroke(menu, color: UIKitChassis.signal)
        for y in [27.0, 34.0, 41.0] {
            let row = UIBezierPath()
            row.move(to: CGPoint(x: 41, y: y))
            row.addLine(to: CGPoint(x: 67, y: y))
            stroke(
                row,
                color: UIKitChassis.signal2.withAlphaComponent(0.5),
                dashed: true
            )
        }
    }

    private func drawPastePermission() {
        let clipboard = UIBezierPath(
            roundedRect: CGRect(x: 13, y: 11, width: 31, height: 44),
            cornerRadius: 3
        )
        stroke(clipboard, color: UIKitChassis.signal2)
        let clip = UIBezierPath(
            roundedRect: CGRect(x: 22, y: 7, width: 13, height: 9),
            cornerRadius: 3
        )
        fill(clip, color: UIKitChassis.screen)
        stroke(clip, color: UIKitChassis.signal)
        drawMonoText(
            "?",
            centeredIn: CGRect(x: 13, y: 20, width: 31, height: 27),
            size: 13,
            color: UIKitChassis.signal
        )
        drawArrow(
            from: CGPoint(x: 49, y: 33),
            to: CGPoint(x: 62, y: 33),
            color: UIKitChassis.signal2,
            endHead: true
        )

        let gearCenter = CGPoint(x: 76, y: 33)
        strokeCircle(center: gearCenter, radius: 9, color: UIKitChassis.signal)
        strokeCircle(center: gearCenter, radius: 3, color: UIKitChassis.signal2)
        let teeth = UIBezierPath()
        for angle in stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 4) {
            let inner = CGPoint(
                x: gearCenter.x + CGFloat(cos(angle)) * 10,
                y: gearCenter.y + CGFloat(sin(angle)) * 10
            )
            let outer = CGPoint(
                x: gearCenter.x + CGFloat(cos(angle)) * 13,
                y: gearCenter.y + CGFloat(sin(angle)) * 13
            )
            teeth.move(to: inner)
            teeth.addLine(to: outer)
        }
        stroke(teeth, color: UIKitChassis.signal)
    }

    private func drawPaneBackdrop() {
        let pane = UIBezierPath(
            roundedRect: CGRect(x: 3, y: 4, width: 90, height: 56),
            cornerRadius: 4
        )
        stroke(pane, color: UIKitChassis.signal2)
        for (end, y) in [(38.0, 12.0), (34.0, 17.0), (42.0, 22.0)] {
            let row = UIBezierPath()
            row.move(to: CGPoint(x: 10, y: y))
            row.addLine(to: CGPoint(x: end, y: y))
            stroke(
                row,
                color: UIKitChassis.signal2.withAlphaComponent(0.5),
                dashed: true
            )
        }
    }

    private func drawSelectionBlock() {
        let frame = CGRect(x: 52, y: 43, width: 36, height: 11)
        let block = UIBezierPath(roundedRect: frame, cornerRadius: 1.5)
        fill(block, color: UIKitChassis.screen)
        stroke(block, color: UIKitChassis.signal)
        let dividers = UIBezierPath()
        dividers.move(to: CGPoint(x: 64, y: 43))
        dividers.addLine(to: CGPoint(x: 64, y: 54))
        dividers.move(to: CGPoint(x: 76, y: 43))
        dividers.addLine(to: CGPoint(x: 76, y: 54))
        stroke(dividers, color: UIKitChassis.signal2)
    }

    private func drawPressedText(_ text: String) {
        drawPaneBackdrop()
        let rect = CGRect(x: 6, y: 27, width: 84, height: 12)
        drawMonoText(
            text,
            centeredIn: rect,
            size: 6.6,
            color: UIKitChassis.signal
        )
        let underline = UIBezierPath()
        underline.move(to: CGPoint(x: 10, y: 42))
        underline.addLine(to: CGPoint(x: 86, y: 42))
        stroke(
            underline,
            color: UIKitChassis.signal2.withAlphaComponent(0.5),
            dashed: true
        )
        strokeCircle(
            center: CGPoint(x: 69, y: 33),
            radius: 9,
            color: UIKitChassis.signal,
            dashed: true
        )
    }

    private func drawKeycap(
        _ rect: CGRect,
        label: String,
        labelSize: CGFloat = 12
    ) {
        let key = UIBezierPath(roundedRect: rect, cornerRadius: 3)
        stroke(key, color: UIKitChassis.signal2)
        drawMonoText(
            label,
            centeredIn: rect,
            size: labelSize,
            color: UIKitChassis.signal
        )
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: UIColor,
        startHead: Bool = false,
        endHead: Bool = false
    ) {
        let arrow = UIBezierPath()
        arrow.move(to: start)
        arrow.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        if startHead {
            addArrowHead(to: arrow, at: start, angle: angle + .pi)
        }
        if endHead {
            addArrowHead(to: arrow, at: end, angle: angle)
        }
        stroke(arrow, color: color)
    }

    private func addArrowHead(
        to path: UIBezierPath,
        at point: CGPoint,
        angle: CGFloat
    ) {
        let length: CGFloat = 5
        let spread: CGFloat = .pi / 5
        path.move(to: point)
        path.addLine(to: CGPoint(
            x: point.x - cos(angle - spread) * length,
            y: point.y - sin(angle - spread) * length
        ))
        path.move(to: point)
        path.addLine(to: CGPoint(
            x: point.x - cos(angle + spread) * length,
            y: point.y - sin(angle + spread) * length
        ))
    }

    private func strokeCircle(
        center: CGPoint,
        radius: CGFloat,
        color: UIColor,
        dashed: Bool = false
    ) {
        stroke(
            UIBezierPath(
                ovalIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            ),
            color: color,
            dashed: dashed
        )
    }

    private func fillCircle(center: CGPoint, radius: CGFloat, color: UIColor) {
        fill(
            UIBezierPath(
                ovalIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            ),
            color: color
        )
    }

    private func stroke(
        _ path: UIBezierPath,
        color: UIColor,
        width: CGFloat = Design.strokeWidth,
        dashed: Bool = false
    ) {
        path.lineWidth = width / drawingScale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if dashed {
            let pattern = Design.dash.map { $0 / drawingScale }
            path.setLineDash(pattern, count: pattern.count, phase: 0)
        }
        color.resolvedColor(with: traitCollection).setStroke()
        path.stroke()
    }

    private func fill(_ path: UIBezierPath, color: UIColor) {
        color.resolvedColor(with: traitCollection).setFill()
        path.fill()
    }

    private func drawMonoText(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        color: UIColor
    ) {
        (text as NSString).draw(
            at: point,
            withAttributes: textAttributes(size: size, color: color)
        )
    }

    private func drawMonoText(
        _ text: String,
        centeredIn rect: CGRect,
        size: CGFloat,
        color: UIColor
    ) {
        let attributes = textAttributes(size: size, color: color)
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(
                x: rect.midX - measured.width / 2,
                y: rect.midY - measured.height / 2
            ),
            withAttributes: attributes
        )
    }

    private func textAttributes(
        size: CGFloat,
        color: UIColor
    ) -> [NSAttributedString.Key: Any] {
        // Sized in the figure's own 96 × 64 space, which the context scale
        // already carries to physical size — the chrome fonts' iOS-on-Mac
        // typeScale boost must not apply on top or the Mac rendition draws
        // text 1.3× into the surrounding shapes.
        [
            .font: UIFont.monospacedSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color.resolvedColor(with: traitCollection),
        ]
    }
}
