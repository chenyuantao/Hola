import AppKit

@main
struct AppTileFlowTests {
    static func main() {
        let flow = AppTileFlowView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let pair = [NSView(), NSView()]
        flow.setTiles(pair)
        flow.layoutSubtreeIfNeeded()
        precondition(pair[0].frame.width == AppTileFlowView.tileWidth, "width \(pair[0].frame)")
        precondition(pair[1].frame.minX >= pair[0].frame.maxX, "wide: \(pair.map(\.frame))")
        precondition(!pair[0].frame.intersects(pair[1].frame))
        precondition(pair[0].frame.minX == 0)
        precondition(pair[1].frame.minX < flow.bounds.width / 2, "left-packed: \(pair.map(\.frame))")

        let row = (0..<4).map { _ in NSView() }
        flow.setTiles(row)
        flow.layoutSubtreeIfNeeded()
        precondition(abs(row[2].frame.maxX - flow.bounds.width) < 0.5, "full row: \(row.map(\.frame))")
        precondition(row[3].frame.minX == 0 && row[3].frame.minY >= row[0].frame.maxY)
        precondition(abs(row[1].frame.minX - pair[1].frame.minX) < 0.5, "same gap: \(row[1].frame) \(pair[1].frame)")

        let tiles = [NSView(), NSView(), NSView()]
        flow.setFrameSize(NSSize(width: 240, height: 400))
        flow.setTiles(tiles)
        flow.layoutSubtreeIfNeeded()
        precondition(tiles[1].frame.minX >= tiles[0].frame.maxX, "two columns: \(tiles.map(\.frame))")
        precondition(tiles[2].frame.minY >= tiles[0].frame.maxY, "third row: \(tiles.map(\.frame))")
        precondition(!tiles[0].frame.intersects(tiles[1].frame))
        precondition(!tiles[2].frame.intersects(tiles[0].frame))
        precondition(!tiles[2].frame.intersects(tiles[1].frame))

        flow.setFrameSize(NSSize(width: 100, height: 400))
        flow.needsLayout = true
        flow.layoutSubtreeIfNeeded()
        precondition(tiles[1].frame.minY >= tiles[0].frame.maxY, "narrow: \(tiles.map(\.frame))")
        precondition(tiles[2].frame.minY >= tiles[1].frame.maxY)
        precondition(!tiles[0].frame.intersects(tiles[1].frame))
        print("ok")
    }
}
