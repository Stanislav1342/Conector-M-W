import AppKit

final class HandoffCue {
    private var panel: NSPanel?
    private var dismiss: DispatchWorkItem?

    func show(at point: CGPoint, entering: Bool) {
        guard let main = NSScreen.screens.first else { return }
        let location = CGPoint(x: point.x, y: main.frame.maxY - point.y - 1)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return }
        if panel == nil {
            let next = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 186, height: 36),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            next.isOpaque = false
            next.backgroundColor = .clear
            next.hasShadow = true
            next.ignoresMouseEvents = true
            next.hidesOnDeactivate = false
            next.level = .statusBar
            next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let label = NSTextField(labelWithString: "")
            label.tag = 450
            label.alignment = .center
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            let holder = NSView(frame: next.contentView!.bounds)
            holder.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: holder.centerYAnchor)
            ])
            if #available(macOS 26.0, *) {
                // Liquid Glass capsule, matching system HUDs on current macOS.
                let glass = NSGlassEffectView(frame: holder.frame)
                glass.cornerRadius = holder.frame.height / 2
                glass.contentView = holder
                next.contentView = glass
                next.hasShadow = false
            } else {
                let material = NSVisualEffectView(frame: holder.frame)
                material.material = .hudWindow
                material.blendingMode = .behindWindow
                material.state = .active
                material.wantsLayer = true
                material.layer?.cornerRadius = 11
                material.layer?.masksToBounds = true
                holder.autoresizingMask = [.width, .height]
                material.addSubview(holder)
                next.contentView = material
            }
            panel = next
        }
        guard let panel else { return }
        dismiss?.cancel()
        (panel.contentView?.viewWithTag(450) as? NSTextField)?.stringValue = entering ? "↑  Управление Windows" : "↓  Управление Mac"
        let bounds = screen.visibleFrame
        let width = panel.frame.width
        let x = max(bounds.minX + 12, min(point.x - width / 2, bounds.maxX - width - 12))
        let y = bounds.maxY - panel.frame.height - 10
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let destination = CGPoint(x: x, y: y)
        panel.alphaValue = reduced ? 1 : 0
        panel.setFrameOrigin(CGPoint(x: x, y: reduced ? y : y + (entering ? -8 : 8)))
        panel.orderFrontRegardless()
        if !reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().setFrameOrigin(destination)
                panel.animator().alphaValue = 1
            }
        }
        let action = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        dismiss = action
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: action)
    }
}
