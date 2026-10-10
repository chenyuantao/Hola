import AppKit

final class AppTileFlowView: NSView {
    static let tileWidth: CGFloat = 96
    static let minimumGap: CGFloat = 16
    private var tiles: [NSView] = []
    private var tileHeight: CGFloat = 96
    private var laidOutColumns = 0

    override var isFlipped: Bool { true }

    func setTiles(_ tiles: [NSView]) {
        self.tiles.forEach { $0.removeFromSuperview() }
        self.tiles = tiles
        var height: CGFloat = 0
        for tile in tiles {
            // 位置由 layout() 写 frame。若关掉 autoresizing，再在 layout 里装约束，
            // 约束要等下一轮才生效，这一轮图标都停在 (0, 0)，后加的会盖住先加的。
            tile.translatesAutoresizingMaskIntoConstraints = true
            let widthLock = tile.widthAnchor.constraint(equalToConstant: Self.tileWidth)
            widthLock.isActive = true
            height = max(height, tile.fittingSize.height)
            widthLock.isActive = false
            addSubview(tile)
        }
        if height > 1 { tileHeight = ceil(height) }
        laidOutColumns = 0
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func columnCapacity(for width: CGFloat) -> Int {
        let stride = Self.tileWidth + Self.minimumGap
        guard width >= Self.tileWidth, stride > 0 else { return 1 }
        return max(1, Int((width + Self.minimumGap) / stride))
    }

    override var intrinsicContentSize: NSSize {
        guard !tiles.isEmpty else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }
        let width = bounds.width > 1 ? bounds.width : Self.tileWidth
        let columns = min(tiles.count, columnCapacity(for: width))
        let rows = Int(ceil(Double(tiles.count) / Double(columns)))
        let height = CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * Self.minimumGap
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        guard !tiles.isEmpty else {
            super.layout()
            return
        }
        let capacity = columnCapacity(for: bounds.width)
        let columns = min(tiles.count, capacity)
        let columnsChanged = columns != laidOutColumns
        laidOutColumns = columns
        // 间隙按整行容量算：排满一行时正好贴住两边，不满一行时从左依次排。
        let full = CGFloat(capacity) * Self.tileWidth
        let gap = capacity > 1 ? max(Self.minimumGap, (bounds.width - full) / CGFloat(capacity - 1)) : Self.minimumGap
        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = CGFloat(column) * (Self.tileWidth + gap)
            let y = CGFloat(row) * (tileHeight + Self.minimumGap)
            tile.frame = NSRect(x: x, y: y, width: Self.tileWidth, height: tileHeight)
        }
        super.layout()
        if columnsChanged { invalidateIntrinsicContentSize() }
    }
}
