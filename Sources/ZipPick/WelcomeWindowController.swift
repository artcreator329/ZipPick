import AppKit

/// Accepts archives dragged in from Finder.
private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = !urls(sender).isEmpty
        return highlighted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let dropped = urls(sender)
        guard !dropped.isEmpty else { return false }
        onDrop?(dropped)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 14, yRadius: 14)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            box.fill()
        }
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        box.lineWidth = 2
        box.setLineDash([7, 5], count: 2, phase: 0)
        box.stroke()
    }
}

/// Shown when ZipPick is opened on its own, so nobody lands on an empty screen.
final class WelcomeWindowController: NSObject {
    let window: NSWindow
    private let onOpen: ([URL]) -> Void
    private let onChoose: () -> Void

    init(onOpen: @escaping ([URL]) -> Void, onChoose: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onChoose = onChoose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "ZipPick"
        window.isReleasedWhenClosed = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: "Extract only the files you need")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Drop a zip, rar or 7z file here")
        subtitle.textColor = .secondaryLabelColor
        let button = NSButton(title: "Choose Archive…", target: self, action: #selector(choose))
        button.keyEquivalent = "\r"
        button.controlSize = .large

        let dropStack = NSStackView(views: [icon, title, subtitle, button])
        dropStack.orientation = .vertical
        dropStack.spacing = 12
        dropStack.setCustomSpacing(16, after: subtitle)

        let drop = DropView(frame: .zero)
        drop.onDrop = { [weak self] in self?.onOpen($0) }

        let tipTitle = NSTextField(labelWithString: "Even quicker, from Finder")
        tipTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let tip = NSTextField(wrappingLabelWithString:
            "Right-click any zip, rar or 7z file and choose “Extract Selected Files…”. "
            + "It is at the bottom of the menu, under Quick Actions or Services.")
        tip.textColor = .secondaryLabelColor
        tip.alignment = .center
        let tipStack = NSStackView(views: [tipTitle, tip])
        tipStack.orientation = .vertical
        tipStack.spacing = 4

        let content = NSView()
        window.contentView = content
        for view in [drop, dropStack, tipStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            drop.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            drop.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            drop.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            dropStack.centerXAnchor.constraint(equalTo: drop.centerXAnchor),
            dropStack.centerYAnchor.constraint(equalTo: drop.centerYAnchor),
            dropStack.topAnchor.constraint(greaterThanOrEqualTo: drop.topAnchor, constant: 24),
            tipStack.topAnchor.constraint(equalTo: drop.bottomAnchor, constant: 16),
            tipStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            tipStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            tipStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        window.center()
    }

    @objc private func choose() { onChoose() }
}
