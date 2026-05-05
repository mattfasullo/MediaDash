// SimianTreeView.swift
// Phase 2: NSOutlineView-backed tree for Finder-parity drag/drop UX.
// Replaces the SwiftUI List + ReorderGapView in folderBrowserView.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Context menu action enum

enum SimianTreeContextAction {
    case uploadTo(folderId: String?, folderName: String?)
    case uploadStagedFiles(folderId: String?, folderName: String?)
    case newFolderWithSelection(treeId: String)
    case newFolder(parentFolderId: String?)
    case beginRename(treeId: String)
    case addDate(treeId: String, useUploadTime: Bool)
    case copyLink(treeId: String)
    case openInBrowser(treeId: String)
    case downloadFolder(folderId: String, folderName: String)
    case downloadFile(fileId: String)
    case sortChildrenAlphabetically(folderId: String?)
    case delete(treeId: String)
}

// MARK: - Stable item reference for NSOutlineView

/// NSOutlineView requires stable object identity for items across reloads.
/// We keep one instance per treeId in a coordinator cache and update its properties.
final class SimianTreeNode: NSObject {
    enum Kind { case folder, file }
    let kind: Kind
    var folder: SimianFolder?
    var file: SimianFile?
    var parentFolderId: String?

    init(folder: SimianFolder, parentFolderId: String?) {
        self.kind = .folder; self.folder = folder; self.parentFolderId = parentFolderId
    }
    init(file: SimianFile, parentFolderId: String?) {
        self.kind = .file; self.file = file; self.parentFolderId = parentFolderId
    }

    var treeId: String {
        if let f = folder { return "f-\(f.id)" }
        if let f = file { return "file-\(f.id)" }
        return ""
    }
    var itemId: String? { folder?.id ?? file?.id }
    var displayName: String { folder?.name ?? file?.title ?? "" }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? SimianTreeNode else { return false }
        return treeId == o.treeId
    }
    override var hash: Int { treeId.hashValue }
}

enum SimianDropTargeting {
    /// Reserve the top/bottom slices of a row for gap-based sibling reordering.
    /// The center band means "drop into this folder".
    static func shouldDropOnFolder(yInRow: CGFloat, rowHeight: CGFloat) -> Bool {
        guard rowHeight > 0 else { return false }
        let normalizedY = max(0, min(yInRow / rowHeight, 1))
        return normalizedY >= 0.30 && normalizedY <= 0.70
    }
}

// MARK: - NSViewRepresentable

struct SimianTreeView: NSViewRepresentable {
    // Data (all value types; coordinator diffs on update)
    let projectId: String
    let currentFolders: [SimianFolder]
    let currentFiles: [SimianFile]
    let folderChildrenCache: [String: [SimianFolder]]
    let folderFilesCache: [String: [SimianFile]]
    let loadingFolderIds: Set<String>
    let expandedFolderIds: Set<String>
    let selectedItemIds: Set<String>
    let inlineRenameItemId: String?
    let currentParentFolderId: String?
    let stagedFileCount: Int
    let focusTrigger: Int

    @Binding var inlineRenameText: String

    // Callbacks into SimianPostView
    var onToggleExpand: (String) -> Void
    var onSpringLoadExpand: (String) -> Void
    var onLoadChildren: (String) -> Void
    var onReorderFolders: (_ projectId: String, _ folderIds: [String], _ parentId: String?, _ dropBeforeId: String?) -> Void
    var onReorderFiles: (_ projectId: String, _ fileIds: [String], _ parentId: String, _ dropBeforeId: String?) -> Void
    var onMoveIntoFolder: (_ projectId: String, _ itemIds: [String], _ targetFolderId: String) -> Void
    var onExternalFileDrop: (_ providers: [NSItemProvider], _ folderId: String?, _ folderName: String?) -> Bool
    var onSelectionChange: (Set<String>) -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    var onContextAction: (SimianTreeContextAction) -> Void

    func makeCoordinator() -> SimianTreeCoordinator { SimianTreeCoordinator(view: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder

        let ov = SimianAppKitOutlineView()
        ov.coordinator = context.coordinator
        ov.dataSource = context.coordinator
        ov.delegate = context.coordinator
        ov.headerView = nil
        ov.rowHeight = 24
        ov.indentationPerLevel = 10
        ov.usesAlternatingRowBackgroundColors = true
        ov.selectionHighlightStyle = .regular
        ov.allowsMultipleSelection = true
        ov.allowsEmptySelection = true
        ov.floatsGroupRows = false
        ov.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        col.resizingMask = .autoresizingMask
        ov.addTableColumn(col)
        ov.outlineTableColumn = col

        let types: [NSPasteboard.PasteboardType] = [
            .string,
            NSPasteboard.PasteboardType(rawValue: UTType.utf8PlainText.identifier),
            NSPasteboard.PasteboardType(rawValue: UTType.plainText.identifier),
            .fileURL
        ]
        ov.registerForDraggedTypes(types)
        ov.setDraggingSourceOperationMask(.move, forLocal: true)
        ov.setDraggingSourceOperationMask([.move, .copy], forLocal: false)
        // Prefer insertion gaps over “on row” drops so sibling reorder is easier than “move into folder”.
        ov.draggingDestinationFeedbackStyle = .gap

        sv.documentView = ov
        context.coordinator.outlineView = ov
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }
}

// MARK: - NSOutlineView subclass

final class SimianAppKitOutlineView: NSOutlineView {
    weak var coordinator: SimianTreeCoordinator?

    /// Loose follow-scroll for keyboard selection: only nudge the clip when the row leaves a vertical
    /// “comfort band” inside the visible rect, instead of tracking every selection change like a locked view.
    override func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < numberOfRows else {
            super.scrollRowToVisible(row)
            return
        }
        let rowRect = rect(ofRow: row)
        guard !rowRect.isNull, rowRect.height > 0 else {
            super.scrollRowToVisible(row)
            return
        }
        let vis = visibleRect
        let visH = vis.height
        guard visH > 0 else {
            super.scrollRowToVisible(row)
            return
        }
        let edge = max(48, rowHeight * 2.5)
        let comfortTop = vis.minY + edge
        let comfortBottom = vis.maxY - edge
        if rowRect.minY >= comfortTop && rowRect.maxY <= comfortBottom {
            return
        }
        if rowRect.minY < comfortTop && rowRect.maxY > comfortBottom {
            super.scrollRowToVisible(row)
            return
        }
        var targetOriginY = vis.minY
        if rowRect.maxY > comfortBottom {
            targetOriginY = rowRect.maxY - visH + edge
        }
        if rowRect.minY < comfortTop {
            targetOriginY = rowRect.minY - edge
        }
        let maxOriginY = max(0, bounds.height - visH)
        targetOriginY = min(max(0, targetOriginY), maxOriginY)
        if abs(targetOriginY - vis.minY) < 0.5 { return }
        scroll(NSPoint(x: 0, y: targetOriginY))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let row = self.row(at: pt)
        let node = row >= 0 ? item(atRow: row) as? SimianTreeNode : nil
        return coordinator?.buildContextMenu(for: node, outlineView: self)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Coordinator

final class SimianTreeCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    var view: SimianTreeView
    weak var outlineView: SimianAppKitOutlineView?

    // Stable item cache — one object per treeId
    private(set) var nodeCache: [String: SimianTreeNode] = [:]

    // Spring-load state
    private var springLoadTimer: Timer?
    private var springLoadTarget: SimianTreeNode?

    // Prevent feedback loops
    private var syncingSelection = false
    private var syncingExpansion = false

    // Focus trigger: -1 means "never applied"; fires makeFirstResponder on first mount and every bump
    private var lastAppliedFocusTrigger = -1

    // Track what we last applied so `update()` is idempotent
    private var prevExpandedIds: Set<String> = []
    private var prevSelectedIds: Set<String> = []

    init(view: SimianTreeView) { self.view = view }

    // MARK: - Update from SwiftUI

    func update(from newView: SimianTreeView) {
        let prev = view
        view = newView
        guard let ov = outlineView else { return }

        let dataChanged =
            prev.currentFolders != newView.currentFolders ||
            prev.currentFiles != newView.currentFiles ||
            prev.folderChildrenCache != newView.folderChildrenCache ||
            prev.folderFilesCache != newView.folderFilesCache

        if dataChanged {
            refreshNodeCache(from: newView)
            ov.reloadData()
            // reloadData() clears NSOutlineView selection even when SwiftUI’s selectedItemIds are unchanged;
            // re-apply so the blue highlight matches keyboard/focus state.
            syncSelectionToOutlineView(newView.selectedItemIds, in: ov)
        }

        if newView.expandedFolderIds != prevExpandedIds {
            prevExpandedIds = newView.expandedFolderIds
            syncExpansion(in: ov, expandedIds: newView.expandedFolderIds)
        }

        if newView.focusTrigger != lastAppliedFocusTrigger {
            lastAppliedFocusTrigger = newView.focusTrigger
            DispatchQueue.main.async { [weak self] in
                guard let ov = self?.outlineView else { return }
                ov.window?.makeFirstResponder(ov)
            }
        }

        if newView.selectedItemIds != prevSelectedIds && !syncingSelection {
            prevSelectedIds = newView.selectedItemIds
            syncSelectionToOutlineView(newView.selectedItemIds, in: ov)
        }

        // Reload rows where inline rename state changed
        if prev.inlineRenameItemId != newView.inlineRenameItemId {
            let affected = Set([prev.inlineRenameItemId, newView.inlineRenameItemId].compactMap { $0 })
            for treeId in affected {
                if let n = nodeCache[treeId] {
                    let row = ov.row(forItem: n)
                    if row >= 0 { ov.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
                }
            }
        }
    }

    // MARK: - Node cache

    private func cachedNode(forFolder f: SimianFolder, parentFolderId: String?) -> SimianTreeNode {
        let key = "f-\(f.id)"
        if let n = nodeCache[key] { n.folder = f; n.parentFolderId = parentFolderId; return n }
        let n = SimianTreeNode(folder: f, parentFolderId: parentFolderId); nodeCache[key] = n; return n
    }

    private func cachedNode(forFile f: SimianFile, parentFolderId: String?) -> SimianTreeNode {
        let key = "file-\(f.id)"
        if let n = nodeCache[key] { n.file = f; n.parentFolderId = parentFolderId; return n }
        let n = SimianTreeNode(file: f, parentFolderId: parentFolderId); nodeCache[key] = n; return n
    }

    private func refreshNodeCache(from v: SimianTreeView) {
        for f in v.currentFolders { _ = cachedNode(forFolder: f, parentFolderId: v.currentParentFolderId) }
        for f in v.currentFiles { _ = cachedNode(forFile: f, parentFolderId: v.currentParentFolderId) }
        for (pid, children) in v.folderChildrenCache { for f in children { _ = cachedNode(forFolder: f, parentFolderId: pid) } }
        for (pid, files) in v.folderFilesCache { for f in files { _ = cachedNode(forFile: f, parentFolderId: pid) } }
    }

    private func syncExpansion(in ov: NSOutlineView, expandedIds: Set<String>) {
        guard !syncingExpansion else { return }
        syncingExpansion = true
        defer { syncingExpansion = false }

        for folderId in expandedIds {
            if let n = nodeCache["f-\(folderId)"], !ov.isItemExpanded(n) { ov.expandItem(n) }
        }
        var rowsToCollapse: [SimianTreeNode] = []
        for row in 0..<ov.numberOfRows {
            guard let n = ov.item(atRow: row) as? SimianTreeNode,
                  n.kind == .folder,
                  let fid = n.itemId,
                  !expandedIds.contains(fid),
                  ov.isItemExpanded(n) else { continue }
            rowsToCollapse.append(n)
        }
        for n in rowsToCollapse { ov.collapseItem(n) }
    }

    /// Row order for drops must match `outlineView(_:child:ofItem:)` / `folderSiblings` — not only `folderChildrenCache`,
    /// because navigated-in listings live in `currentFolders` / `currentFiles` while the cache may still be empty.
    private func orderedDropRowNodes(parentFolderId: String?) -> [SimianTreeNode] {
        let folders: [SimianFolder]
        let files: [SimianFile]
        if parentFolderId == nil || parentFolderId == view.currentParentFolderId {
            folders = view.currentFolders
            files = view.currentFiles
        } else {
            let pid = parentFolderId!
            folders = view.folderChildrenCache[pid] ?? []
            files = view.folderFilesCache[pid] ?? []
        }
        return folders.compactMap { nodeCache["f-\($0.id)"] } + files.compactMap { nodeCache["file-\($0.id)"] }
    }

    private func syncSelectionToOutlineView(_ ids: Set<String>, in ov: NSOutlineView) {
        let idxSet = IndexSet(ids.compactMap { id -> Int? in
            guard let n = nodeCache[id] else { return nil }
            let row = ov.row(forItem: n); return row >= 0 ? row : nil
        })
        syncingSelection = true
        defer { syncingSelection = false }
        ov.selectRowIndexes(idxSet, byExtendingSelection: false)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return view.currentFolders.count + view.currentFiles.count }
        guard let n = item as? SimianTreeNode, n.kind == .folder, let fid = n.itemId else { return 0 }
        return (view.folderChildrenCache[fid]?.count ?? 0) + (view.folderFilesCache[fid]?.count ?? 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if index < view.currentFolders.count {
                return cachedNode(forFolder: view.currentFolders[index], parentFolderId: view.currentParentFolderId)
            }
            return cachedNode(forFile: view.currentFiles[index - view.currentFolders.count], parentFolderId: view.currentParentFolderId)
        }
        guard let parent = item as? SimianTreeNode, let fid = parent.itemId else { return NSObject() }
        let cf = view.folderChildrenCache[fid] ?? []
        if index < cf.count { return cachedNode(forFolder: cf[index], parentFolderId: fid) }
        let files = view.folderFilesCache[fid] ?? []
        return cachedNode(forFile: files[index - cf.count], parentFolderId: fid)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? SimianTreeNode, n.kind == .folder, let fid = n.itemId else { return false }
        if let children = view.folderChildrenCache[fid] { return !children.isEmpty || !(view.folderFilesCache[fid]?.isEmpty ?? true) }
        return true // Not loaded yet — assume expandable
    }

    // MARK: - NSOutlineViewDelegate (cell views + row height)

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SimianTreeNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("SimianCell")
        var cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SimianTreeCell
        if cell == nil { cell = SimianTreeCell(); cell?.identifier = id }

        let isRenaming = view.inlineRenameItemId == node.treeId
        let isLoading = node.kind == .folder && view.loadingFolderIds.contains(node.itemId ?? "")
        cell?.configure(
            node: node,
            isInlineRenaming: isRenaming,
            renameText: isRenaming ? view.inlineRenameText : node.displayName,
            isLoading: isLoading,
            onRenameTextChange: { [weak self] t in self?.view.inlineRenameText = t },
            onCommitRename: { [weak self] in self?.view.onCommitRename() },
            onCancelRename: { [weak self] in self?.view.onCancelRename() }
        )
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 24 }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

    func outlineViewSelectionDidChange(_ notification: Foundation.Notification) {
        guard let ov = (notification as NSNotification).object as? NSOutlineView, !syncingSelection else { return }
        syncingSelection = true; defer { syncingSelection = false }
        var ids = Set<String>()
        ov.selectedRowIndexes.forEach { if let n = ov.item(atRow: $0) as? SimianTreeNode { ids.insert(n.treeId) } }
        prevSelectedIds = ids
        view.onSelectionChange(ids)
    }

    func outlineViewItemWillExpand(_ notification: Foundation.Notification) {
        guard !syncingExpansion else { return }
        let userInfo = (notification as NSNotification).userInfo
        guard let node = userInfo?["NSObject"] as? SimianTreeNode,
              let fid = node.itemId else { return }
        if view.folderChildrenCache[fid] == nil { view.onLoadChildren(fid) }
        view.onToggleExpand(fid)
    }

    func outlineViewItemWillCollapse(_ notification: Foundation.Notification) {
        guard !syncingExpansion else { return }
        let userInfo = (notification as NSNotification).userInfo
        guard let node = userInfo?["NSObject"] as? SimianTreeNode,
              let fid = node.itemId else { return }
        view.onToggleExpand(fid)
    }

    // MARK: - Drag source

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SimianTreeNode else { return nil }
        let selectedNodes = outlineView.selectedRowIndexes
            .compactMap { outlineView.item(atRow: $0) as? SimianTreeNode }
            .filter { $0.kind == node.kind }
        let treeIds = selectedNodes.contains(node) ? selectedNodes.map(\.treeId) : [node.treeId]
        let type = node.kind == .folder ? "folder" : "file"
        let payload = buildSimianDragPayload(type: type, projectId: view.projectId, parentId: node.parentFolderId, itemIds: treeIds)
        let pb = NSPasteboardItem()
        for t: NSPasteboard.PasteboardType in [.string, NSPasteboard.PasteboardType(rawValue: UTType.utf8PlainText.identifier)] {
            pb.setString(payload, forType: t)
        }
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        let nodes = draggedItems.compactMap { $0 as? SimianTreeNode }
        guard nodes.count > 1 else { return }
        // Multi-item drag: show stack icon + count badge
        let imgSize = CGSize(width: 40, height: 40)
        let img = NSImage(size: imgSize)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let iconCfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .light)
        NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconCfg)?
            .draw(in: CGRect(x: 2, y: 2, width: 30, height: 36), from: .zero, operation: .sourceOver, fraction: 0.85)
        let badge = "\(nodes.count)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
        let badgeW = (badge as NSString).size(withAttributes: attrs).width + 8
        let badgeRect = CGRect(x: imgSize.width - badgeW, y: 0, width: badgeW, height: 15)
        NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: badgeRect, xRadius: 7, yRadius: 7).fill()
        (badge as NSString).draw(in: badgeRect.insetBy(dx: 4, dy: 1), withAttributes: attrs)
        img.unlockFocus()
        session.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, idx, stop in
            if idx == 0 {
                item.imageComponentsProvider = {
                    let c = NSDraggingImageComponent(key: .icon)
                    c.contents = img
                    c.frame = CGRect(origin: .zero, size: imgSize)
                    return [c]
                }
                stop.pointee = true
            }
        }
    }

    // MARK: - Drop destination

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex childIndex: Int) -> NSDragOperation {
        let location = outlineView.convert(info.draggingLocation, from: nil)
        let hoveredRow = outlineView.row(at: location)
        let hoveredNode = hoveredRow >= 0 ? (outlineView.item(atRow: hoveredRow) as? SimianTreeNode) : nil
        let isHoveringFolderCenter: Bool = {
            guard let hoveredNode, hoveredNode.kind == .folder else { return false }
            let rowRect = outlineView.rect(ofRow: hoveredRow)
            let yInRow = location.y - rowRect.minY
            return SimianDropTargeting.shouldDropOnFolder(yInRow: yInRow, rowHeight: rowRect.height)
        }()

        // External Finder file drag
        let isExternal = (info.draggingSource as? NSOutlineView) !== outlineView
        if isExternal && info.draggingPasteboard.types?.contains(.fileURL) == true {
            if isHoveringFolderCenter, let hoveredNode {
                outlineView.setDropItem(hoveredNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            return .copy
        }

        // Internal Simian drag
        guard let str = info.draggingPasteboard
            .string(forType: NSPasteboard.PasteboardType(rawValue: UTType.utf8PlainText.identifier))
            ?? info.draggingPasteboard.string(forType: .string),
              let parsed = parseSimianMultiDrag(str) else { return [] }

        // Can't drop onto a dragged item
        if let targetNode = item as? SimianTreeNode, parsed.itemIds.contains(targetNode.treeId) { return [] }
        if let hoveredNode, parsed.itemIds.contains(hoveredNode.treeId) { return [] }

        // With .gap feedback style, NSOutlineView often proposes insert-as-child.
        // If the pointer is clearly centered on a folder row, treat it as explicit move-into.
        if isHoveringFolderCenter, let hoveredNode {
            outlineView.setDropItem(hoveredNode, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        // NSOutlineView's default tracking proposes "insert as child N of folder X" when the cursor is
        // near the bottom half of a collapsed folder row.  For reordering siblings that is wrong:
        // we want "insert before folder X at folder X's parent level".  Redirect the proposal whenever
        // the proposed item is a folder that is NOT the actual parent of the dragged items (i.e. it is
        // a sibling being misproposed as parent).  The NSOutlineViewDropOnItemIndex case (-1) is
        // intentional "drop ON folder" (move-into) and must NOT be redirected.  Likewise, when the
        // proposed item IS the true parent (its id matches parsed.parentId), it is a legitimate
        // "insert inside parent" proposal and must not be redirected.
        if childIndex != NSOutlineViewDropOnItemIndex,
           let proposedNode = item as? SimianTreeNode,
           proposedNode.itemId != parsed.parentId {
            let idxInParent = outlineView.childIndex(forItem: proposedNode)
            if idxInParent >= 0 {
                let parentItem = outlineView.parent(forItem: proposedNode)
                outlineView.setDropItem(parentItem, dropChildIndex: idxInParent)
            }
        }

        // Spring-load: hover over closed folder → expand after delay (external drops only; internal drags are almost always reorder)
        let folderTarget = item as? SimianTreeNode
        if isExternal {
            if let fn = folderTarget, fn.kind == .folder, !outlineView.isItemExpanded(fn) {
                if springLoadTarget !== fn {
                    springLoadTimer?.invalidate()
                    springLoadTarget = fn
                    springLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { [weak self] _ in
                        guard let self, let fid = fn.itemId else { return }
                        DispatchQueue.main.async { self.view.onSpringLoadExpand(fid) }
                        self.springLoadTimer = nil; self.springLoadTarget = nil
                    }
                }
            } else if springLoadTarget !== folderTarget {
                springLoadTimer?.invalidate(); springLoadTimer = nil; springLoadTarget = nil
            }
        } else if springLoadTarget != nil {
            springLoadTimer?.invalidate(); springLoadTimer = nil; springLoadTarget = nil
        }

        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int) -> Bool {
        let pb = info.draggingPasteboard

        // External Finder file drop
        let isExternal = (info.draggingSource as? NSOutlineView) !== outlineView
        if isExternal, let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let providers = urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
            let targetNode = item as? SimianTreeNode
            let folderId = targetNode?.kind == .folder ? targetNode?.itemId : view.currentParentFolderId
            let folderName: String? = {
                guard let fid = folderId else { return nil }
                return nodeCache["f-\(fid)"]?.displayName
            }()
            _ = view.onExternalFileDrop(providers, folderId, folderName)
            return true
        }

        guard let str = pb.string(forType: NSPasteboard.PasteboardType(rawValue: UTType.utf8PlainText.identifier))
                        ?? pb.string(forType: .string),
              let parsed = parseSimianMultiDrag(str) else { return false }

        if childIndex == NSOutlineViewDropOnItemIndex {
            // Drop ON a folder row → move into it
            guard let fn = item as? SimianTreeNode, fn.kind == .folder, let fid = fn.itemId else { return false }
            view.onMoveIntoFolder(parsed.projectId, parsed.itemIds, fid)
        } else {
            // Drop between rows → reorder
            let parentFolderId: String?
            if let pn = item as? SimianTreeNode, pn.kind == .folder { parentFolderId = pn.itemId }
            else { parentFolderId = view.currentParentFolderId }

            // Find the item at childIndex (insert-before slot) in the combined folder+file row list.
            let all = orderedDropRowNodes(parentFolderId: parentFolderId)

            let folderIds = parsed.itemIds.compactMap { $0.hasPrefix("f-") ? String($0.dropFirst(2)) : nil }
            let fileIds = parsed.itemIds.compactMap { $0.hasPrefix("file-") ? String($0.dropFirst(5)) : nil }

            if !folderIds.isEmpty {
                // Map combined-list childIndex to folder-only "insert before" id (folders and files share one visual
                // order but Simian/API reorder is per-type; legacy kind-matched anchors dropped nil on cross-type gaps).
                let folderOrderIds = all.compactMap { $0.kind == .folder ? $0.itemId : nil }
                let insertPosAmongRemain = all.prefix(childIndex).filter { $0.kind == .folder }.compactMap(\.itemId).filter { !folderIds.contains($0) }.count
                let remainFolderIds = folderOrderIds.filter { !folderIds.contains($0) }
                let safeFolderPos = min(max(0, insertPosAmongRemain), remainFolderIds.count)
                let dropBeforeId = safeFolderPos < remainFolderIds.count ? remainFolderIds[safeFolderPos] : nil
                view.onReorderFolders(parsed.projectId, folderIds, parentFolderId, dropBeforeId)
            }
            if !fileIds.isEmpty, let pid = parentFolderId {
                let fileOrderIds = all.compactMap { $0.kind == .file ? $0.itemId : nil }
                let insertPosAmongRemain = all.prefix(childIndex).filter { $0.kind == .file }.compactMap(\.itemId).filter { !fileIds.contains($0) }.count
                let remainFileIds = fileOrderIds.filter { !fileIds.contains($0) }
                let safeFilePos = min(max(0, insertPosAmongRemain), remainFileIds.count)
                let dropBeforeId = safeFilePos < remainFileIds.count ? remainFileIds[safeFilePos] : nil
                view.onReorderFiles(parsed.projectId, fileIds, pid, dropBeforeId)
            }
        }
        return true
    }

    // MARK: - Context menu

    func buildContextMenu(for node: SimianTreeNode?, outlineView: NSOutlineView) -> NSMenu? {
        let menu = NSMenu()
        let v = view

        func add(_ title: String, action: SimianTreeContextAction) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action
            menu.addItem(item)
        }

        func addAddDateSubmenu(forTreeId treeId: String) {
            let sub = NSMenu()
            let today = NSMenuItem(title: "Today's Date", action: #selector(menuAction(_:)), keyEquivalent: "")
            today.target = self
            today.representedObject = SimianTreeContextAction.addDate(treeId: treeId, useUploadTime: false)
            sub.addItem(today)
            let upload = NSMenuItem(title: "Upload Date", action: #selector(menuAction(_:)), keyEquivalent: "")
            upload.target = self
            upload.representedObject = SimianTreeContextAction.addDate(treeId: treeId, useUploadTime: true)
            sub.addItem(upload)
            let parent = NSMenuItem(title: "Add Date", action: nil, keyEquivalent: "")
            parent.submenu = sub
            menu.addItem(parent)
        }

        if let node {
            let offerBatchRename = v.selectedItemIds.contains(node.treeId) && v.selectedItemIds.count > 1
            let removeTitle: String = {
                if v.selectedItemIds.contains(node.treeId), v.selectedItemIds.count > 1 {
                    return "Remove \(v.selectedItemIds.count) Items from Simian\u{2026}"
                }
                return "Remove from Simian\u{2026}"
            }()
            if node.kind == .folder, let fid = node.itemId, let fn = node.folder?.name {
                add("Upload to \u{201C}\(fn)\u{201D}\u{2026}", action: .uploadTo(folderId: fid, folderName: fn))
                if v.stagedFileCount > 0 { add("Upload \(v.stagedFileCount) staged file(s) here", action: .uploadStagedFiles(folderId: fid, folderName: fn)) }
                menu.addItem(.separator())
                add("New Folder with Selection", action: .newFolderWithSelection(treeId: node.treeId))
                add("New Folder", action: .newFolder(parentFolderId: fid))
                menu.addItem(.separator())
                add(offerBatchRename ? "Batch Rename\u{2026}" : "Rename\u{2026}", action: .beginRename(treeId: node.treeId))
                addAddDateSubmenu(forTreeId: node.treeId)
                menu.addItem(.separator())
                add("Copy Link", action: .copyLink(treeId: node.treeId))
                add("Edit on Simian", action: .openInBrowser(treeId: node.treeId))
                add("Download folder contents\u{2026}", action: .downloadFolder(folderId: fid, folderName: fn))
                menu.addItem(.separator())
                add("Sort contents A\u{2013}Z", action: .sortChildrenAlphabetically(folderId: fid))
                menu.addItem(.separator())
                let delItem = NSMenuItem(title: removeTitle, action: #selector(menuAction(_:)), keyEquivalent: "")
                delItem.target = self; delItem.representedObject = SimianTreeContextAction.delete(treeId: node.treeId)
                menu.addItem(delItem)
            } else if node.kind == .file, let fid = node.itemId {
                add("New Folder with Selection", action: .newFolderWithSelection(treeId: node.treeId))
                menu.addItem(.separator())
                add(offerBatchRename ? "Batch Rename\u{2026}" : "Rename\u{2026}", action: .beginRename(treeId: node.treeId))
                addAddDateSubmenu(forTreeId: node.treeId)
                menu.addItem(.separator())
                add("Edit on Simian", action: .openInBrowser(treeId: node.treeId))
                add("Download\u{2026}", action: .downloadFile(fileId: fid))
                menu.addItem(.separator())
                let delItem = NSMenuItem(title: removeTitle, action: #selector(menuAction(_:)), keyEquivalent: "")
                delItem.target = self; delItem.representedObject = SimianTreeContextAction.delete(treeId: node.treeId)
                menu.addItem(delItem)
            }
        } else {
            add("Upload to\u{2026}", action: .uploadTo(folderId: v.currentParentFolderId, folderName: nil))
            if v.stagedFileCount > 0 { add("Upload \(v.stagedFileCount) staged file(s) here", action: .uploadStagedFiles(folderId: v.currentParentFolderId, folderName: nil)) }
            menu.addItem(.separator())
            add("New Folder with Selection", action: .newFolderWithSelection(treeId: ""))
            add("New Folder", action: .newFolder(parentFolderId: v.currentParentFolderId))
            menu.addItem(.separator())
            if let pid = v.currentParentFolderId {
                add("Sort items A\u{2013}Z", action: .sortChildrenAlphabetically(folderId: pid))
                add("Edit on Simian", action: .openInBrowser(treeId: "f-\(pid)"))
            } else {
                add("Sort folders A\u{2013}Z", action: .sortChildrenAlphabetically(folderId: nil))
                add("Edit on Simian", action: .openInBrowser(treeId: ""))
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? SimianTreeContextAction else { return }
        view.onContextAction(action)
    }
}

// MARK: - Cell view

final class SimianTreeCell: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField()
    private let renameField = NSTextField()
    private let spinner = NSProgressIndicator()
    private let typeTagBackView = NSView()
    private let typeTagLabel = NSTextField()

    private var onRenameTextChange: ((String) -> Void)?
    private var onCommitRename: (() -> Void)?
    private var onCancelRename: (() -> Void)?

    // Swapped to make room for the type tag or extend to the trailing edge.
    private var nameLabelToTagConstraint: NSLayoutConstraint!
    private var nameLabelToTrailingConstraint: NSLayoutConstraint!

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        for v in [iconView, nameLabel, renameField, spinner, typeTagBackView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
        }

        iconView.imageScaling = .scaleProportionallyDown

        nameLabel.isEditable = false; nameLabel.isBordered = false; nameLabel.drawsBackground = false
        nameLabel.lineBreakMode = .byTruncatingTail; nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        renameField.isEditable = true; renameField.isBordered = true; renameField.bezelStyle = .roundedBezel
        renameField.font = .systemFont(ofSize: 13); renameField.isHidden = true
        renameField.target = self; renameField.action = #selector(commitRename)
        renameField.delegate = self

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isHidden = true

        typeTagBackView.wantsLayer = true
        typeTagBackView.layer?.cornerRadius = 3
        typeTagBackView.layer?.masksToBounds = true
        typeTagBackView.isHidden = true

        typeTagLabel.isEditable = false; typeTagLabel.isBordered = false; typeTagLabel.drawsBackground = false
        typeTagLabel.lineBreakMode = .byClipping
        typeTagLabel.setContentHuggingPriority(.required, for: .horizontal)
        typeTagLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        typeTagLabel.translatesAutoresizingMaskIntoConstraints = false
        typeTagBackView.addSubview(typeTagLabel)
        typeTagBackView.setContentHuggingPriority(.required, for: .horizontal)
        typeTagBackView.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameLabelToTagConstraint = nameLabel.trailingAnchor.constraint(equalTo: typeTagBackView.leadingAnchor, constant: -4)
        nameLabelToTrailingConstraint = nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        nameLabelToTrailingConstraint.isActive = true

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            renameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            renameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            renameField.centerYAnchor.constraint(equalTo: centerYAnchor),

            typeTagBackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            typeTagBackView.centerYAnchor.constraint(equalTo: centerYAnchor),

            typeTagLabel.leadingAnchor.constraint(equalTo: typeTagBackView.leadingAnchor, constant: 4),
            typeTagLabel.topAnchor.constraint(equalTo: typeTagBackView.topAnchor, constant: 1),
            typeTagLabel.bottomAnchor.constraint(equalTo: typeTagBackView.bottomAnchor, constant: -1),
            typeTagBackView.trailingAnchor.constraint(equalTo: typeTagLabel.trailingAnchor, constant: 4),
        ])
    }

    /// Prefer `media_file` URL, then filename in `title`, for a tag like `.wav`.
    private static func resolvedExtension(_ file: SimianFile) -> String? {
        if let u = file.mediaURL {
            let e = u.pathExtension
            if !e.isEmpty { return e.lowercased() }
        }
        let e = (file.title as NSString).pathExtension
        return e.isEmpty ? nil : e.lowercased()
    }

    private static func iconFromFileTypeString(_ ft: String) -> (symbol: String, color: NSColor)? {
        let s = ft.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("audio") || s == "wav" || s == "mp3" || s == "aiff" || s == "flac" || s == "aac" {
            return ("waveform", .systemTeal)
        }
        if s.hasPrefix("video") || s == "mp4" || s == "mov" || s == "avi" || s == "mxf" || s == "r3d" {
            return ("film", .systemPurple)
        }
        if s.hasPrefix("image") || s == "jpg" || s == "jpeg" || s == "png" || s == "gif" || s == "tiff" || s == "tif" || s == "psd" {
            return ("photo", .systemGreen)
        }
        if s == "pdf" {
            return ("doc.richtext", .systemRed)
        }
        if s.hasPrefix("doc") || s == "txt" || s == "rtf" || s == "pages" || s == "docx" {
            return ("doc.text", .systemOrange)
        }
        return nil
    }

    private static func iconFromExtension(_ ext: String) -> (symbol: String, color: NSColor) {
        let e = ext.lowercased()
        if ["wav", "mp3", "aiff", "aif", "flac", "m4a", "aac"].contains(e) { return ("waveform", .systemTeal) }
        if ["mp4", "mov", "avi", "mxf", "m4v", "r3d", "prores"].contains(e) { return ("film", .systemPurple) }
        if ["jpg", "jpeg", "png", "gif", "tiff", "tif", "psd", "heic", "webp"].contains(e) { return ("photo", .systemGreen) }
        if e == "pdf" { return ("doc.richtext", .systemRed) }
        if ["txt", "rtf", "pages", "docx", "doc"].contains(e) { return ("doc.text", .systemOrange) }
        return ("doc", .secondaryLabelColor)
    }

    private static func iconForFile(_ file: SimianFile) -> (symbol: String, color: NSColor) {
        if let ft = file.fileType, let i = iconFromFileTypeString(ft) { return i }
        if let ext = resolvedExtension(file) { return iconFromExtension(ext) }
        return ("doc", .secondaryLabelColor)
    }

    func configure(
        node: SimianTreeNode,
        isInlineRenaming: Bool,
        renameText: String,
        isLoading: Bool,
        onRenameTextChange: @escaping (String) -> Void,
        onCommitRename: @escaping () -> Void,
        onCancelRename: @escaping () -> Void
    ) {
        self.onRenameTextChange = onRenameTextChange
        self.onCommitRename = onCommitRename
        self.onCancelRename = onCancelRename

        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let simianFile = node.kind == .file ? node.file : nil
        let fileIcon = simianFile.map { SimianTreeCell.iconForFile($0) }

        if node.kind == .folder {
            iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            iconView.contentTintColor = .secondaryLabelColor
        } else if let ft = fileIcon {
            iconView.image = NSImage(systemSymbolName: ft.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            iconView.contentTintColor = ft.color
        } else {
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            iconView.contentTintColor = .secondaryLabelColor
        }

        if isLoading {
            iconView.isHidden = true; spinner.isHidden = false; spinner.startAnimation(nil)
        } else {
            iconView.isHidden = false; spinner.isHidden = true; spinner.stopAnimation(nil)
        }

        if isInlineRenaming {
            nameLabel.isHidden = true; renameField.isHidden = false
            applyTag(nil)
            if renameField.stringValue != renameText { renameField.stringValue = renameText }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                renameField.window?.makeFirstResponder(renameField)
                renameField.currentEditor()?.selectAll(nil)
            }
        } else {
            nameLabel.isHidden = false; renameField.isHidden = true
            nameLabel.stringValue = node.displayName
            if let f = simianFile, let ext = SimianTreeCell.resolvedExtension(f), let ft = fileIcon {
                applyTag((".\(ext)", ft.color))
            } else {
                applyTag(nil)
            }
        }
    }

    private func applyTag(_ tagInfo: (text: String, color: NSColor)?) {
        if let (text, color) = tagInfo {
            typeTagLabel.font = .systemFont(ofSize: 9, weight: .medium)
            typeTagLabel.stringValue = text
            typeTagLabel.textColor = color
            typeTagBackView.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
            typeTagBackView.isHidden = false
            nameLabelToTrailingConstraint.isActive = false
            nameLabelToTagConstraint.isActive = true
        } else {
            typeTagBackView.isHidden = true
            nameLabelToTagConstraint.isActive = false
            nameLabelToTrailingConstraint.isActive = true
        }
    }

    @objc private func commitRename() { onCommitRename?() }
    override func cancelOperation(_ sender: Any?) { onCancelRename?() }
    deinit { Foundation.NotificationCenter.default.removeObserver(self) }
}

extension SimianTreeCell: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Foundation.Notification) {
        guard ((obj as NSNotification).object as? NSTextField) === renameField else { return }
        onRenameTextChange?(renameField.stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancelRename?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { onCommitRename?(); return true }
        return false
    }
}
