import AppKit

// Command-line mode, used for testing the engine without the window:
//   ZipPick --list archive.zip
//   ZipPick --extract archive.zip destination [--keep-paths] path [path…]
let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--list" || arguments[1] == "--extract" {
    do {
        let archive = try openArchive(URL(fileURLWithPath: arguments[2]))
        let tree = ArchiveTree(entries: archive.entries)
        if arguments[1] == "--list" {
            func walk(_ node: Node, _ depth: Int) {
                for child in node.children {
                    print(String(repeating: "  ", count: depth) + child.name + (child.isFolder ? "/" : "  (\(child.totalSize))"))
                    walk(child, depth + 1)
                }
            }
            walk(tree.root, 0)
        } else {
            guard arguments.count >= 5 else { fatalError("usage: --extract zip destination [--keep-paths] path…") }
            var paths = Array(arguments[4...])
            let keep = paths.first == "--keep-paths"
            if keep { paths.removeFirst() }
            for path in paths {
                guard let node = tree.node(atPath: path) else {
                    FileHandle.standardError.write(Data("not in archive: \(path)\n".utf8))
                    exit(2)
                }
                tree.setChecked(node, true)
            }
            let plan = tree.extractionPlan(keepFullPaths: keep)
            let result = try archive.extract(
                plan, to: URL(fileURLWithPath: arguments[3]), policy: .replace,
                progress: { _ in }, isCancelled: { false })
            print("written \(result.written), skipped \(result.skipped)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
