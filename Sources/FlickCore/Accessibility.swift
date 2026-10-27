import AppKit
import ApplicationServices

// MARK: Attribute helpers

func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
        return nil
    }
    return value
}

func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = copy(element, attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func children(_ parent: AXUIElement) -> [AXUIElement] {
    copy(parent, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    copy(element, attribute) as? String
}

func title(_ element: AXUIElement) -> String? {
    string(element, kAXTitleAttribute)
}

func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    var p = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
}

func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else {
        return nil
    }
    var s = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &s) ? s : nil
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let origin = point(element, kAXPositionAttribute),
          let extent = size(element, kAXSizeAttribute) else { return nil }
    return CGRect(origin: origin, size: extent)
}

func setPosition(_ window: AXUIElement, _ p: CGPoint) {
    var p = p
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                 AXValueCreate(.cgPoint, &p)!)
}

func setSize(_ window: AXUIElement, _ s: CGSize) {
    var s = s
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString,
                                 AXValueCreate(.cgSize, &s)!)
}

// MARK: Window menu

/// The first item of the app's Window menu whose title matches.
func windowMenuItem(_ app: AXUIElement, where matches: (String) -> Bool) -> AXUIElement? {
    guard let menuBar = element(app, kAXMenuBarAttribute),
          let menu = children(menuBar).first(where: { title($0) == "Window" })
              .flatMap({ children($0).first }) else { return nil }
    return children(menu).first(where: { title($0).map(matches) ?? false })
}

/// The item at `path` under the app's Window menu, each title matched exactly.
func windowMenuItem(_ app: AXUIElement, path: [String]) -> AXUIElement? {
    guard let first = path.first,
          var item = windowMenuItem(app, where: { $0 == first }) else { return nil }
    for name in path.dropFirst() {
        guard let submenu = children(item).first,
              let next = children(submenu).first(where: { title($0) == name }) else { return nil }
        item = next
    }
    return item
}

// MARK: Windows

/// A window of some app, with the app's Accessibility element.
public struct AppWindow: @unchecked Sendable {
    public let app: AXUIElement
    public let window: AXUIElement
    public let appName: String
    public let bundleIdentifier: String?

    /// The focused (or else main) window of the frontmost app.
    @MainActor
    public static func frontmost() -> AppWindow? {
        guard let running = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let window = element(app, kAXFocusedWindowAttribute)
            ?? element(app, kAXMainWindowAttribute) else { return nil }
        return AppWindow(app: app, window: window, appName: running.localizedName ?? "?",
                         bundleIdentifier: running.bundleIdentifier)
    }

    /// The standard window whose title bar is at `location`, in global
    /// top-left coordinates like CGEvent's, if it isn't covered there.
    @MainActor
    public static func titleBar(at location: CGPoint) -> AppWindow? {
        window(at: location, inTitleBar: true)
    }

    /// The standard window at `location`, anywhere in it, if it isn't covered
    /// there.
    @MainActor
    public static func window(at location: CGPoint) -> AppWindow? {
        window(at: location, inTitleBar: false)
    }

    @MainActor
    private static func window(at location: CGPoint, inTitleBar: Bool) -> AppWindow? {
        let systemWide = AXUIElementCreateSystemWide()
        // Asked from the event tap, which must not stall on a hung app.
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(location.x), Float(location.y),
                                               &hit) == .success,
              let hit, let window = window(containing: hit),
              string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              copy(window, "AXFullScreen") as? Bool != true,
              let windowFrame = FlickCore.frame(of: window) else { return nil }
        if inTitleBar {
            let close = element(window, kAXCloseButtonAttribute).flatMap { FlickCore.frame(of: $0) }
            guard titleBarBand(window: windowFrame, closeButton: close).contains(location) else {
                return nil
            }
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let running = NSRunningApplication(processIdentifier: pid)
        return AppWindow(app: app, window: window, appName: running?.localizedName ?? "?",
                         bundleIdentifier: running?.bundleIdentifier)
    }

    private static func window(containing hit: AXUIElement) -> AXUIElement? {
        if string(hit, kAXRoleAttribute) == kAXWindowRole { return hit }
        if let window = element(hit, kAXWindowAttribute) { return window }
        var current = hit
        for _ in 0..<32 {
            guard let parent = element(current, kAXParentAttribute) else { return nil }
            if string(parent, kAXRoleAttribute) == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }

    /// Brings the window to the front of its app and the app to the front, so
    /// Window-menu commands act on it.
    public func focus() {
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    public var frame: CGRect? { FlickCore.frame(of: window) }

    /// The window's title-bar band, where swipes start (see titleBarBand).
    public var titleBar: CGRect? {
        guard let frame else { return nil }
        let close = element(window, kAXCloseButtonAttribute).flatMap { FlickCore.frame(of: $0) }
        return titleBarBand(window: frame, closeButton: close)
    }
    public var title: String? { FlickCore.title(window) }
}
