import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [PickerWindowController] = []
    private var welcome: WelcomeWindowController?
    private var receivedFile = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMenu()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // When Finder launches us for a zip, the file arrives just after launch. Only ask
        // for one if nothing shows up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.receivedFile, self.controllers.isEmpty else { return }
            self.showWelcome()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    /// Finder's right-click entry: "Extract Selected Files…" (declared under NSServices in Info.plist).
    @objc func pickFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        urls.forEach(open)
    }

    private func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindowController(
                onOpen: { [weak self] urls in urls.forEach { self?.open($0) } },
                onChoose: { [weak self] in self?.openDocument(nil) })
        }
        NSApp.activate(ignoringOtherApps: true)
        welcome?.window.makeKeyAndOrderFront(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        receivedFile = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["zip", "rar", "7z"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Choose an archive to pick items from"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    @objc func findInArchive(_ sender: Any?) {
        controllers.first { $0.window.isKeyWindow }?.focusSearch()
    }

    private func open(_ url: URL) {
        receivedFile = true
        NSApp.activate(ignoringOtherApps: true)
        if let existing = controllers.first(where: { $0.window.representedURL == url }) {
            existing.show()
            return
        }
        do {
            let controller = try PickerWindowController(url: url)
            controller.onClose = { [weak self, weak controller] in
                self?.controllers.removeAll { $0 === controller }
            }
            controllers.append(controller)
            controller.show()
            welcome?.window.orderOut(nil)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t open “\(url.lastPathComponent)”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            if controllers.isEmpty { showWelcome() }
        }
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About ZipPick", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide ZipPick", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit ZipPick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "ZipPick"))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find", action: #selector(findInArchive(_:)), keyEquivalent: "f")
        main.addItem(submenu(edit, title: "Edit"))

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
