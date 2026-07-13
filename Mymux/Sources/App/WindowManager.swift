import AppKit

// MymuxWindow handles scroll wheel at the window level so we can deal with
// alternate-screen terminals (e.g. Claude Code / Ink) that SwiftTerm's own
// scrollWheel() doesn't handle — it only touches the scrollback buffer which
// is empty in alternate-screen mode.
//
// Dispatch logic (per scroll event):
//   A. Terminal has scrollback (canScroll) → buffer scroll via scrollUp/Down
//   B. Alternate screen + mouse reporting on → forward as X10/SGR scroll mouse event
//   C. Alternate screen, no mouse reporting → accumulate delta; pageUp/Down when
//      enough has built up (avoids a page-jump on every tiny trackpad movement)
private final class MymuxWindow: NSWindow {
    // Accumulated scroll delta for the alt-screen pageUp/Down path (C).
    // Reset whenever we switch to a scrollable terminal (path A).
    private var altScrollAccum: CGFloat = 0
    private let altScrollThreshold: CGFloat = 50

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel {
            // Resolve the effective vertical delta regardless of input device.
            // Trackpad: hasPreciseScrollingDeltas=true, use scrollingDeltaY (pixels).
            // Mouse wheel: use deltaY (line steps, scaled to pixel equivalents).
            let delta: CGFloat = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.deltaY * 12

            if delta != 0, let termView = terminalView(at: event.locationInWindow) {
                handleScroll(delta: delta, termView: termView, windowPoint: event.locationInWindow,
                             isPrecise: event.hasPreciseScrollingDeltas)
                return
            }
        }
        super.sendEvent(event)
    }

    private func handleScroll(delta: CGFloat, termView: MymuxTerminalView,
                              windowPoint: NSPoint, isPrecise: Bool) {
        if termView.canScroll {
            altScrollAccum = 0
            let lines = max(1, Int(abs(delta) / 8))
            if delta > 0 { termView.scrollUp(lines: lines) }
            else         { termView.scrollDown(lines: lines) }
        } else if termView.terminal.mouseMode != .off {
            // Alternate screen with mouse reporting (Claude Code/Ink enables this).
            // Send X10/SGR scroll event — button 64 = up, 65 = down.
            let local = termView.convert(windowPoint, from: nil)
            let cols  = max(1, termView.terminal.cols)
            let rows  = max(1, termView.terminal.rows)
            let cellW = termView.bounds.width  / CGFloat(cols)
            let cellH = termView.bounds.height / CGFloat(rows)
            let gridX  = max(0, min(cols - 1, Int(local.x / cellW)))
            let gridY  = max(0, min(rows - 1, Int((termView.bounds.height - local.y) / cellH)))
            let pixelX = Int(local.x)
            let pixelY = Int(termView.bounds.height - local.y)
            let button = delta > 0 ? 64 : 65
            termView.terminal.sendEvent(buttonFlags: button, x: gridX, y: gridY,
                                        pixelX: pixelX, pixelY: pixelY)
        } else {
            // Alternate screen, no mouse reporting.
            // Accumulate delta so small trackpad movements don't trigger page jumps.
            altScrollAccum += delta
            while abs(altScrollAccum) >= altScrollThreshold {
                if altScrollAccum > 0 {
                    termView.pageUp()
                    altScrollAccum -= altScrollThreshold
                } else {
                    termView.pageDown()
                    altScrollAccum += altScrollThreshold
                }
            }
        }
    }

    // Walk UP from the deepest hit view to find MymuxTerminalView even when
    // SwiftTerm's internal leaf views are the actual hit target.
    private func terminalView(at windowPoint: NSPoint) -> MymuxTerminalView? {
        guard let cv = contentView else { return nil }
        let localPt = cv.convert(windowPoint, from: nil)
        var view: NSView? = cv.hitTest(localPt)
        while let v = view {
            if let t = v as? MymuxTerminalView { return t }
            view = v.superview
        }
        return nil
    }
}

final class WindowManager {
    private var window: NSWindow?
    private var splitVC: MainSplitViewController?

    func showMainWindow(sqliteStore: SQLiteStore, sessionManager: SessionManager) {
        let split = MainSplitViewController(sqliteStore: sqliteStore)
        splitVC = split

        // Wire session manager to view controllers
        sessionManager.sidebarViewController = split.sidebarVC
        sessionManager.terminalAreaViewController = split.terminalAreaVC

        let window = MymuxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "mymux"
        window.contentViewController = split
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func focusTerminal(id: String) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        splitVC?.sidebarVC.selectTerminal(id: id)
    }

    var mainSplitVC: MainSplitViewController? { splitVC }
}
