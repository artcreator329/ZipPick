import Foundation

final class Node {
    enum State { case off, on, mixed }

    let name: String
    var entry: ArchiveEntry?
    weak var parent: Node?
    var children: [Node] = []
    /// Children that pass the current search filter.
    var visibleChildren: [Node] = []
    fileprivate var index: [String: Node] = [:]

    /// Leaves are files and empty folders: the things that actually get ticked.
    var leafCount = 0
    var checkedCount = 0
    var totalSize: UInt64 = 0
    var checked = false

    init(name: String, parent: Node?) {
        self.name = name
        self.parent = parent
    }

    var isLeaf: Bool { children.isEmpty }
    var isFolder: Bool { !children.isEmpty || entry?.isDirectory == true }

    var state: State {
        if isLeaf { return checked ? .on : .off }
        if checkedCount == 0 { return .off }
        return checkedCount == leafCount ? .on : .mixed
    }

    var components: [String] {
        var parts: [String] = []
        var node: Node? = self
        while let n = node, n.parent != nil {
            parts.append(n.name)
            node = n.parent
        }
        return parts.reversed()
    }
}

final class ArchiveTree {
    let root = Node(name: "", parent: nil)
    private(set) var isFiltering = false

    init(entries: [ArchiveEntry]) {
        for entry in entries {
            // Finder's resource-fork clutter is never something people want to pick.
            if entry.components.first == "__MACOSX" || entry.components.last == ".DS_Store" { continue }
            var node = root
            for part in entry.components {
                if let existing = node.index[part] {
                    node = existing
                } else {
                    let child = Node(name: part, parent: node)
                    node.index[part] = child
                    node.children.append(child)
                    node = child
                }
            }
            node.entry = entry
        }
        finalize(root)
    }

    private func finalize(_ node: Node) {
        node.index = [:]
        if node.isLeaf {
            node.leafCount = 1
            node.totalSize = node.entry?.uncompressedSize ?? 0
            return
        }
        node.children.forEach(finalize)
        node.children.sort {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        node.visibleChildren = node.children
        node.leafCount = node.children.reduce(0) { $0 + $1.leafCount }
        node.totalSize = node.children.reduce(0) { $0 + $1.totalSize }
    }

    // MARK: Ticking

    /// Ticks or unticks a node and everything under it. While a search is active only the
    /// rows that match the search are touched.
    func setChecked(_ node: Node, _ on: Bool) {
        let delta = apply(node, on)
        var ancestor = node.parent
        while let a = ancestor {
            a.checkedCount += delta
            ancestor = a.parent
        }
    }

    private func apply(_ node: Node, _ on: Bool) -> Int {
        if node.isLeaf {
            guard node.checked != on else { return 0 }
            node.checked = on
            node.checkedCount = on ? 1 : 0
            return on ? 1 : -1
        }
        let delta = (isFiltering ? node.visibleChildren : node.children).reduce(0) { $0 + apply($1, on) }
        node.checkedCount += delta
        return delta
    }

    /// True when every row the user can currently see under `node` is ticked.
    func allChecked(_ node: Node) -> Bool {
        if node.isLeaf { return node.checked }
        if !isFiltering { return node.checkedCount == node.leafCount }
        return node.visibleChildren.allSatisfy(allChecked)
    }

    var checkedSize: UInt64 { size(of: root) }

    private func size(of node: Node) -> UInt64 {
        if node.checkedCount == 0 { return 0 }
        if node.checkedCount == node.leafCount { return node.totalSize }
        return node.children.reduce(0) { $0 + size(of: $1) }
    }

    // MARK: Search

    func filter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        isFiltering = !q.isEmpty
        if q.isEmpty { reset(root) } else { _ = narrow(root, q) }
    }

    private func reset(_ node: Node) {
        node.visibleChildren = node.children
        node.children.forEach(reset)
    }

    private func narrow(_ node: Node, _ query: String) -> Bool {
        if node.parent != nil,
           node.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            reset(node)
            return true
        }
        node.visibleChildren = node.children.filter { narrow($0, query) }
        return !node.visibleChildren.isEmpty
    }

    // MARK: Plan

    func node(atPath path: String) -> Node? {
        var node = root
        for part in path.split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == String(part) }) else { return nil }
            node = next
        }
        return node === root ? nil : node
    }

    /// Turns the ticks into a list of files to write.
    ///
    /// Unless `keepFullPaths` is set, the folders above the selection are dropped: ticking
    /// `a/b/c.txt` alone gives `c.txt`, and ticking the whole folder `a/b` gives `b/…`.
    func extractionPlan(keepFullPaths: Bool) -> ExtractionPlan {
        var tops: [Node] = []
        func collectTops(_ node: Node) {
            guard node.checkedCount > 0 else { return }
            if node !== root, node.state == .on { tops.append(node); return }
            node.children.forEach(collectTops)
        }
        collectTops(root)
        guard !tops.isEmpty else { return ExtractionPlan() }

        var strip = 0
        if !keepFullPaths {
            var common = Array(tops[0].components.dropLast())
            for top in tops.dropFirst() {
                let parent = Array(top.components.dropLast())
                var shared = 0
                while shared < common.count, shared < parent.count, common[shared] == parent[shared] { shared += 1 }
                common = Array(common.prefix(shared))
            }
            strip = common.count
        }

        var plan: [PlanItem] = []
        func collect(_ node: Node) {
            if node.isLeaf {
                if let entry = node.entry {
                    plan.append(PlanItem(entry: entry, relativeComponents: Array(node.components.dropFirst(strip))))
                }
                return
            }
            node.children.forEach(collect)
        }
        tops.forEach(collect)
        return ExtractionPlan(items: plan, roots: tops.map(\.components), strip: strip)
    }
}
