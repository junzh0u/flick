import AppKit

/// A frosted, click-through preview of where a swipe will put the window,
/// shown while the fingers are still down: a rounded rectangle at the target
/// frame with a symbol for the action, like macOS's own tiling preview. It
/// glides when the swipe changes direction and fades out when it ends.
@MainActor
final class PreviewOverlay {
    private let panel: NSPanel
    private let icon = NSImageView()
    private var visible = false
    /// How opaque the preview gets, so the windows under it stay readable.
    private let opacity = 0.75

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.alphaValue = 0
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                    .fullScreenAuxiliary, .transient]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
        panel.contentView = effect

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .white.withAlphaComponent(0.85)
        icon.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        effect.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
    }

    /// Shows the preview at `frame`, in global top-left coordinates like
    /// Accessibility's, gliding there if it is already showing.
    func show(_ frame: CGRect, symbol: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let target = cocoaFrame(frame.insetBy(dx: 4, dy: 4))
        if !visible {
            panel.setFrame(target, display: false)
            panel.orderFrontRegardless()
        }
        visible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = opacity
        }
    }

    func hide() {
        guard visible else { return }
        visible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [panel, weak self] in
            MainActor.assumeIsolated {
                if self?.visible == false { panel.orderOut(nil) }
            }
        }
    }

    /// Accessibility's top-left origin, y down, to AppKit's bottom-left, y up.
    private func cocoaFrame(_ r: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}
