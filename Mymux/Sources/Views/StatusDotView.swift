import AppKit

final class StatusDotView: NSView {
    var status: DisplayStatus = .suspended {
        didSet {
            if oldValue != status {
                needsDisplay = true
                if status == .thinking {
                    startPulsingIfNeeded()
                } else {
                    stopPulsing()
                }
            }
        }
    }

    private var pulseTimer: Timer?

    override var intrinsicContentSize: NSSize {
        return NSSize(width: 12, height: 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        switch status {
        case .active:
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect).fill()

        case .thinking:
            NSColor.systemBlue.withAlphaComponent(pulseAlpha()).setFill()
            NSBezierPath(ovalIn: rect).fill()

        case .waiting:
            // amber filled circle + amber stroked outer ring
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.systemOrange.setStroke()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = 1.5
            ring.stroke()

        case .suspended:
            // gray stroked open circle (unfilled)
            NSColor.systemGray.setStroke()
            let circle = NSBezierPath(ovalIn: rect)
            circle.lineWidth = 1.5
            circle.stroke()

        case .completed:
            // dim checkmark
            NSColor.systemGray.withAlphaComponent(0.6).setStroke()
            let check = NSBezierPath()
            check.lineWidth = 1.5
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            let cx = bounds.midX
            let cy = bounds.midY
            check.move(to: NSPoint(x: cx - 3, y: cy))
            check.line(to: NSPoint(x: cx - 1, y: cy - 2))
            check.line(to: NSPoint(x: cx + 3, y: cy + 2.5))
            check.stroke()
        }
    }

    private func pulseAlpha() -> CGFloat {
        let t = Date().timeIntervalSinceReferenceDate
        return 0.4 + 0.6 * CGFloat(sin(t * 3.0) * 0.5 + 0.5)
    }

    private func startPulsingIfNeeded() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.status == .thinking else { return }
            self.needsDisplay = true
        }
    }

    private func stopPulsing() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    deinit {
        pulseTimer?.invalidate()
    }
}
