import AppKit

final class FileDropBar {
    private var panel: NSPanel?
    private var dropView: DropTargetView?
    private var label: NSTextField?
    private var dismissWork: DispatchWorkItem?
    private(set) var isShowingDropZone = false

    var onDrop: (([URL]) -> Void)?

    private func ensurePanel() -> (NSPanel, DropTargetView, NSTextField) {
        if let panel, let dropView, let label {
            return (panel, dropView, label)
        }
        let frame = NSRect(x: 0, y: 0, width: 380, height: 54)
        let next = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        next.isOpaque = false
        next.backgroundColor = .clear
        next.hasShadow = true
        next.ignoresMouseEvents = false
        next.hidesOnDeactivate = false
        next.level = .screenSaver
        next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let target = DropTargetView(frame: frame)
        target.onHighlightChange = { [weak target] highlighted in
            target?.layer?.backgroundColor = highlighted
                ? NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
                : NSColor.clear.cgColor
        }
        target.onDropFiles = { [weak self] urls in
            self?.hideDropZone()
            self?.onDrop?(urls)
        }

        let field = NSTextField(labelWithString: "")
        field.alignment = .center
        field.font = .systemFont(ofSize: 13.5, weight: .semibold)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        target.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: target.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: target.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: target.centerYAnchor)
        ])

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.cornerRadius = frame.height / 2
            glass.contentView = target
            next.contentView = glass
            next.hasShadow = false
        } else {
            let material = NSVisualEffectView(frame: frame)
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = frame.height / 2
            material.layer?.masksToBounds = true
            target.autoresizingMask = [.width, .height]
            material.addSubview(target)
            next.contentView = material
        }

        self.panel = next
        self.dropView = target
        self.label = field
        return (next, target, field)
    }

    func showDropZone(near x: CGFloat, on screen: NSScreen, destinationLabel: String) {
        let (panel, target, field) = ensurePanel()
        dismissWork?.cancel()
        isShowingDropZone = true
        panel.ignoresMouseEvents = false
        field.stringValue = "Отпустите для отправки на Windows (\(destinationLabel))"
        target.setHighlighted(false)
        let width: CGFloat = 380
        let height: CGFloat = 54
        let vf = screen.visibleFrame
        let posX = max(vf.minX + 12, min(x - width / 2, vf.maxX - width - 12))
        let posY = screen.frame.maxY - height - 8
        panel.setFrame(NSRect(x: posX, y: posY, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hideDropZone() {
        isShowingDropZone = false
        dropView?.setHighlighted(false)
        panel?.orderOut(nil)
    }

    func showStatus(_ message: String, on screen: NSScreen? = nil, duration: TimeInterval = 2.6) {
        guard !isShowingDropZone,
              let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let (panel, target, field) = ensurePanel()
        dismissWork?.cancel()
        panel.ignoresMouseEvents = true
        target.setHighlighted(false)
        field.stringValue = message
        let width: CGFloat = 380
        let height: CGFloat = 42
        let vf = targetScreen.visibleFrame
        let posX = vf.midX - width / 2
        let posY = vf.maxY - height - 10
        panel.setFrame(NSRect(x: posX, y: posY, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShowingDropZone else { return }
            self.panel?.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

private final class DropTargetView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    var onHighlightChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = frameRect.height / 2
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setHighlighted(_ value: Bool) {
        onHighlightChange?(value)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let canRead = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                              options: [.urlReadingFileURLsOnly: true])
        setHighlighted(canRead)
        return canRead ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setHighlighted(false)
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return false }
        DispatchQueue.main.async {
            self.onDropFiles?(fileURLs)
        }
        return true
    }
}
