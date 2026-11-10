import AppKit
import UniformTypeIdentifiers

private final class NameCell: NSTableCellView {
    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        check.allowsMixedState = true
        label.lineBreakMode = .byTruncatingMiddle
        // The checkbox must stay its own size; the name takes whatever width is left.
        check.setContentHuggingPriority(.required, for: .horizontal)
        check.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [check, icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class PickerOutlineView: NSOutlineView {
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onSpace?() } else { super.keyDown(with: event) }
    }
}

private final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

final class PickerWindowController: NSObject, NSWindowDelegate, NSOutlineViewDataSource,
    NSOutlineViewDelegate, NSSearchFieldDelegate {

    let window: NSWindow
    var onClose: (() -> Void)?

    private let archive: Archive
    private let tree: ArchiveTree
    private let outline = PickerOutlineView()
    private let searchField = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let keepPaths = NSButton(checkboxWithTitle: "Keep full folder paths", target: nil, action: nil)
    private let extractToButton = NSButton(title: "Extract To…", target: nil, action: nil)
    private let extractHereButton = NSButton(title: "Extract Here", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var cancelFlag: CancelFlag?
    private var icons: [String: NSImage] = [:]
    private let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    init(url: URL) throws {
        archive = try openArchive(url)
        tree = ArchiveTree(entries: archive.entries)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = url.lastPathComponent
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 320)
        window.delegate = self
        buildInterface()
        window.center()
        if tree.root.children.count == 1 { outline.expandItem(tree.root.children[0]) }
        updateStatus()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(outline)
    }

    func focusSearch() { window.makeFirstResponder(searchField) }

    func windowWillClose(_ notification: Notification) {
        cancelFlag?.set()
        onClose?()
    }

    // MARK: Interface

    private func buildInterface() {
        let content = NSView()
        window.contentView = content

        searchField.placeholderString = "Search this archive"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        let selectAll = NSButton(title: "Select All", target: self, action: #selector(selectAllItems))
        let selectNone = NSButton(title: "Select None", target: self, action: #selector(selectNoItems))
        let top = NSStackView(views: [searchField, selectAll, selectNone])
        top.spacing = 8

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Name"
        nameColumn.minWidth = 240
        nameColumn.resizingMask = .autoresizingMask
        let sizeColumn = NSTableColumn(identifier: .init("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 90
        sizeColumn.minWidth = 70
        sizeColumn.maxWidth = 140
        sizeColumn.resizingMask = .userResizingMask
        outline.addTableColumn(nameColumn)
        outline.addTableColumn(sizeColumn)
        outline.outlineTableColumn = nameColumn
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.rowHeight = 24
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.onSpace = { [weak self] in self?.toggleSelectedRows() }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        for button in [keepPaths, extractToButton, extractHereButton, cancelButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        keepPaths.toolTip = "Off: only the ticked items are written. On: their parent folders from the archive are recreated too."
        extractToButton.target = self
        extractToButton.action = #selector(extractTo)
        extractHereButton.target = self
        extractHereButton.action = #selector(extractHere)
        extractHereButton.keyEquivalent = "\r"
        extractHereButton.toolTip = "Extract next to the archive"
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.widthAnchor.constraint(equalToConstant: 160).isActive = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelExtraction)
        cancelButton.isHidden = true
        let bottom = NSStackView(views: [status, progressBar, cancelButton, keepPaths, extractToButton, extractHereButton])
        bottom.spacing = 12
        bottom.distribution = .fill

        for view in [top, scroll, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    // MARK: Outline

    private func node(_ item: Any?) -> Node { (item as? Node) ?? tree.root }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item).visibleChildren.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).visibleChildren[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !node(item).visibleChildren.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = node(item)
        if tableColumn?.identifier.rawValue == "size" {
            let id = NSUserInterfaceItemIdentifier("sizeCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                let label = NSTextField(labelWithString: "")
                label.alignment = .right
                label.textColor = .secondaryLabelColor
                label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                cell.identifier = id
                return cell
            }()
            cell.textField?.stringValue = sizeFormatter.string(fromByteCount: Int64(clamping: node.totalSize))
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("nameCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NameCell ?? {
            let cell = NameCell(frame: .zero)
            cell.identifier = id
            cell.check.target = self
            cell.check.action = #selector(checkClicked(_:))
            return cell
        }()
        cell.label.stringValue = node.name
        cell.icon.image = icon(for: node)
        cell.check.state = controlState(node)
        return cell
    }

    private func controlState(_ node: Node) -> NSControl.StateValue {
        switch node.state {
        case .on: return .on
        case .off: return .off
        case .mixed: return .mixed
        }
    }

    private func icon(for node: Node) -> NSImage {
        let key = node.isFolder ? "/" : (node.name as NSString).pathExtension.lowercased()
        if let cached = icons[key] { return cached }
        let type: UTType = node.isFolder ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        icons[key] = image
        return image
    }

    // MARK: Ticking

    @objc private func checkClicked(_ sender: NSButton) {
        let row = outline.row(for: sender)
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        tree.setChecked(node, !tree.allChecked(node))
        refreshChecks()
    }

    private func toggleSelectedRows() {
        let nodes = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
        guard !nodes.isEmpty else { return }
        let turnOn = !nodes.allSatisfy(tree.allChecked)
        nodes.forEach { tree.setChecked($0, turnOn) }
        refreshChecks()
    }

    @objc private func selectAllItems() { setAll(true) }
    @objc private func selectNoItems() { setAll(false) }

    private func setAll(_ on: Bool) {
        tree.root.visibleChildren.forEach { tree.setChecked($0, on) }
        refreshChecks()
    }

    private func refreshChecks() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? NameCell,
                  let node = self.outline.item(atRow: row) as? Node else { return }
            cell.check.state = self.controlState(node)
        }
        updateStatus()
    }

    private func updateStatus(_ message: String? = nil) {
        let count = tree.root.checkedCount
        extractToButton.isEnabled = count > 0
        extractHereButton.isEnabled = count > 0
        if let message { status.stringValue = message; return }
        if count == 0 {
            status.stringValue = "Tick the items you want. \(tree.root.leafCount) in this archive."
        } else {
            let size = sizeFormatter.string(fromByteCount: Int64(clamping: tree.checkedSize))
            status.stringValue = "\(count) of \(tree.root.leafCount) selected · \(size)"
        }
    }

    // MARK: Search

    func controlTextDidChange(_ notification: Notification) {
        tree.filter(searchField.stringValue)
        outline.reloadData()
        if tree.isFiltering { outline.expandItem(nil, expandChildren: true) }
    }

    // MARK: Extraction

    @objc private func extractHere() {
        prepareExtraction(to: archive.url.deletingLastPathComponent())
    }

    @objc private func extractTo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = archive.url.deletingLastPathComponent()
        panel.prompt = "Extract"
        panel.message = "Choose where to put the selected items"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // Let the panel's sheet finish closing before another sheet may appear.
            DispatchQueue.main.async { self?.prepareExtraction(to: url) }
        }
    }

    private func prepareExtraction(to destination: URL) {
        let plan = tree.extractionPlan(keepFullPaths: keepPaths.state == .on)
        guard !plan.isEmpty else { return }
        if let locked = plan.items.first(where: { $0.entry.isEncrypted && !$0.entry.isDirectory }) {
            show(ZipError.encrypted(locked.entry.path))
            return
        }
        let existing = plan.existingCount(in: destination)
        guard existing > 0 else {
            run(plan, to: destination, policy: .replace)
            return
        }
        let alert = NSAlert()
        alert.messageText = existing == 1
            ? "1 item already exists in “\(destination.lastPathComponent)”."
            : "\(existing) items already exist in “\(destination.lastPathComponent)”."
        alert.informativeText = "Replace them with the versions from the archive, or keep what is there and extract only the rest?"
        alert.addButton(withTitle: "Skip Existing")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.run(plan, to: destination, policy: .skip)
            case .alertSecondButtonReturn: self?.run(plan, to: destination, policy: .replace)
            default: break
            }
        }
    }

    private func run(_ plan: ExtractionPlan, to destination: URL, policy: ConflictPolicy) {
        let flag = CancelFlag()
        cancelFlag = flag
        setBusy(true)
        updateStatus("Extracting…")
        let archive = archive
        let bar = progressBar

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lastUpdate = 0.0
            let outcome = Result {
                try archive.extract(plan, to: destination, policy: policy, progress: { fraction in
                    let now = CFAbsoluteTimeGetCurrent()
                    guard now - lastUpdate > 0.05 else { return }
                    lastUpdate = now
                    DispatchQueue.main.async { bar.doubleValue = fraction }
                }, isCancelled: { flag.isSet })
            }
            DispatchQueue.main.async { self?.finish(outcome, destination: destination) }
        }
    }

    private func finish(_ outcome: Result<ExtractResult, Error>, destination: URL) {
        cancelFlag = nil
        setBusy(false)
        switch outcome {
        case .success(let result):
            var message = "Extracted \(result.written) item\(result.written == 1 ? "" : "s") to “\(destination.lastPathComponent)”"
            if result.skipped > 0 { message += ", skipped \(result.skipped)" }
            updateStatus(message + ".")
            let reveal = result.topLevel.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(50)
            if !reveal.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(Array(reveal)) }
        case .failure(ZipError.cancelled):
            updateStatus("Extraction cancelled.")
        case .failure(let error):
            updateStatus("Extraction failed.")
            show(error)
        }
    }

    @objc private func cancelExtraction() { cancelFlag?.set() }

    private func setBusy(_ busy: Bool) {
        progressBar.doubleValue = 0
        progressBar.isHidden = !busy
        cancelButton.isHidden = !busy
        keepPaths.isHidden = busy
        extractToButton.isHidden = busy
        extractHereButton.isHidden = busy
        outline.isEnabled = !busy
        searchField.isEnabled = !busy
    }

    private func show(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t extract"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
