import AppKit

final class DesktopWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable across reboots and reconnects, unlike the display ID.
    var stableKey: String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return String(displayID)
    }
}

extension Span {
    /// `screen`'s place among every connected screen as they're arranged; nil with a single screen.
    @MainActor
    static func of(_ screen: NSScreen, among screens: [NSScreen] = NSScreen.screens) -> Span? {
        guard screens.count > 1 else { return nil }
        let all = screens.reduce(CGRect.null) { $0.union($1.frame) }
        let f = screen.frame
        guard all.width > 0, all.height > 0 else { return nil }
        return Span(total: all.size, rect: CGRect(
            x: (f.minX - all.minX) / all.width, y: (all.maxY - f.maxY) / all.height,
            width: f.width / all.width, height: f.height / all.height
        ))
    }
}

enum DesktopHitTest {
    /// True when nothing but the desktop (Finder's icon layer or our wallpaper) is under `point`, in CG (top-left) coordinates.
    static func isDesktopExposed(at point: CGPoint) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 0, layer < 1000,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point)
            else { continue }
            if (window[kCGWindowOwnerPID as String] as? Int32) == ownPID { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            return false
        }
        return true
    }
}
