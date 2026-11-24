import AppKit

private let legacyFilenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

func extractDraggedFileURLs(from pb: NSPasteboard) -> [URL] {
    if let urls = pb.readObjects(forClasses: [NSURL.self],
                                 options: [.urlReadingFileURLsOnly: true]) as? [URL] {
        let resolved = urls.compactMap { ($0 as NSURL).filePathURL ?? ($0.isFileURL ? $0 : nil) }
        if !resolved.isEmpty {
            return resolved
        }
    }
    if let paths = pb.propertyList(forType: legacyFilenamesPasteboardType) as? [String] {
        return paths.map { URL(fileURLWithPath: $0) }
    }
    return []
}

func dragPasteboardHasFiles() -> Bool {
    NSPasteboard(name: .drag).availableType(from: [.fileURL, legacyFilenamesPasteboardType]) != nil
}

final class FileDropBar {
    private var panel: NSPanel?
    private var dropView: DropTargetView?
    private var label: NSTextField?
    private var materialView: NSVisualEffectView?
    private var glassCornerUpdater: ((CGFloat) -> Void)?
    private var dismissWork: DispatchWorkItem?
    private(set) var isShowingDropZone = false

    var onDrop: (([URL]) -> Void)?

    private func ensurePanel() -> (NSPanel, DropTargetView, NSTextField) {
        if let panel, let dropView, let label {
            return (panel, dropView, label)
        }
        let frame = NSRect(x: 0, y: 0, width: 250, height: 108)
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
        target.onRejectedDrag = { [weak self] in
            self?.hideDropZone()
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
            glass.cornerRadius = 22
            glass.contentView = target
            next.contentView = glass
            next.hasShadow = false
            glassCornerUpdater = { [weak glass] radius in
                glass?.cornerRadius = radius
            }
        } else {
            let material = NSVisualEffectView(frame: frame)
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 22
            material.layer?.masksToBounds = true
            target.autoresizingMask = [.width, .height]
            material.addSubview(target)
            next.contentView = material
            materialView = material
        }

        self.panel = next
        self.dropView = target
        self.label = field
        return (next, target, field)
    }

    private func applyCornerRadius(_ radius: CGFloat, target: DropTargetView) {
        target.layer?.cornerRadius = radius
        glassCornerUpdater?(radius)
        materialView?.layer?.cornerRadius = radius
    }

    func showDropZone(nearQuartzY quartzY: CGFloat, on screen: NSScreen) {
        let (panel, target, field) = ensurePanel()
        dismissWork?.cancel()
        isShowingDropZone = true
        panel.ignoresMouseEvents = false
        target.onClick = nil
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        field.stringValue = "Отпустите файл\nдля Windows → Загрузки"
        target.setHighlighted(false)
        applyCornerRadius(22, target: target)
        let width: CGFloat = 250
        let height: CGFloat = 108
        let vf = screen.visibleFrame
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let appKitY = primaryMaxY - quartzY
        let posX = screen.frame.maxX - width - 6
        let posY = max(vf.minY + 20, min(appKitY - height / 2, vf.maxY - height - 20))
        panel.setFrame(NSRect(x: posX, y: posY, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hideDropZone() {
        isShowingDropZone = false
        dropView?.setHighlighted(false)
        panel?.orderOut(nil)
    }

    func showStatus(_ message: String, on screen: NSScreen? = nil,
                    duration: TimeInterval = 3.2, revealURLs: [URL]? = nil) {
        guard !isShowingDropZone,
              let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let (panel, target, field) = ensurePanel()
        dismissWork?.cancel()
        if let revealURLs, !revealURLs.isEmpty {
            panel.ignoresMouseEvents = false
            target.onClick = { [weak self] in
                self?.dismissWork?.cancel()
                self?.panel?.orderOut(nil)
                NSWorkspace.shared.activateFileViewerSelecting(revealURLs)
            }
        } else {
            panel.ignoresMouseEvents = true
            target.onClick = nil
        }
        target.setHighlighted(false)
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingMiddle
        field.stringValue = message
        applyCornerRadius(23, target: target)
        let width: CGFloat = 440
        let height: CGFloat = 46
        let vf = targetScreen.visibleFrame
        let posX = vf.midX - width / 2
        let posY = vf.maxY - height - 10
        panel.setFrame(NSRect(x: posX, y: posY, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isShowingDropZone else { return }
            self.dropView?.onClick = nil
            self.panel?.orderOut(nil)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

private final class DropTargetView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    var onRejectedDrag: (() -> Void)?
    var onHighlightChange: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        registerForDraggedTypes([.fileURL, legacyFilenamesPasteboardType])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setHighlighted(_ value: Bool) {
        onHighlightChange?(value)
    }

    override func mouseUp(with event: NSEvent) {
        if let onClick {
            onClick()
            return
        }
        super.mouseUp(with: event)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = extractDraggedFileURLs(from: sender.draggingPasteboard)
        if urls.isEmpty {
            setHighlighted(false)
            DispatchQueue.main.async {
                self.onRejectedDrag?()
            }
            return []
        }
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setHighlighted(false)
        let fileURLs = extractDraggedFileURLs(from: sender.draggingPasteboard)
        guard !fileURLs.isEmpty else { return false }
        DispatchQueue.main.async {
            self.onDropFiles?(fileURLs)
        }
        return true
    }
}

final class StatusItemDropView: NSView {
    var onDropFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        registerForDraggedTypes([.fileURL, legacyFilenamesPasteboardType])
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func setHighlighted(_ highlighted: Bool) {
        layer?.backgroundColor = highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor
            : NSColor.clear.cgColor
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = extractDraggedFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else {
            setHighlighted(false)
            return []
        }
        setHighlighted(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        setHighlighted(false)
        isHidden = true
        let urls = extractDraggedFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async {
            self.onDropFiles?(urls)
        }
        return true
    }
}
