import AppKit

/// Greedy row-packing layout used by Apple Photos / Lightroom / Eagle / etc.
///
/// Each item carries an aspect ratio (read from `Asset.pixelWidth/Height`
/// upstream). We walk items left-to-right accumulating width-at-target-height;
/// when the row is full we scale it uniformly so the row exactly fills the
/// container width and every item in that row gets the same height.
///
/// The last (incomplete) row keeps the target row height rather than being
/// stretched.
final class JustifiedGridLayout: NSCollectionViewLayout {

    var targetRowHeight: CGFloat = 220 { didSet { invalidateLayout() } }
    var horizontalGap: CGFloat = 4
    var verticalGap: CGFloat = 4
    var contentInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    /// Aspect ratios in item order. Supplied by the data source upfront so we
    /// can pack without per-item delegate calls.
    var itemSizes: [CGSize] = [] { didSet { invalidateLayout() } }

    private var itemFrames: [CGRect] = []
    private var contentHeight: CGFloat = 0
    private var lastContainerWidth: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let cv = collectionView else { return }
        let containerWidth = cv.bounds.width - contentInsets.left - contentInsets.right
        lastContainerWidth = cv.bounds.width

        guard containerWidth > 0, !itemSizes.isEmpty else {
            itemFrames = []
            contentHeight = 0
            return
        }

        var frames: [CGRect] = []
        frames.reserveCapacity(itemSizes.count)
        var y = contentInsets.top
        var rowStart = 0
        var rowAccumWidth: CGFloat = 0

        func flush(upToExclusive end: Int, fillWidth: Bool) {
            let count = end - rowStart
            guard count > 0 else { return }
            var totalAspect: CGFloat = 0
            for i in rowStart..<end {
                let s = itemSizes[i]
                totalAspect += (s.height > 0) ? (s.width / s.height) : 1
            }
            let totalGap = CGFloat(count - 1) * horizontalGap
            let rowHeight: CGFloat = fillWidth
                ? (containerWidth - totalGap) / totalAspect
                : targetRowHeight
            var x = contentInsets.left
            for i in rowStart..<end {
                let s = itemSizes[i]
                let aspect: CGFloat = (s.height > 0) ? (s.width / s.height) : 1
                let w = aspect * rowHeight
                frames.append(CGRect(x: x, y: y, width: w, height: rowHeight))
                x += w + horizontalGap
            }
            y += rowHeight + verticalGap
            rowStart = end
            rowAccumWidth = 0
        }

        for i in 0..<itemSizes.count {
            let s = itemSizes[i]
            let aspect: CGFloat = (s.height > 0) ? (s.width / s.height) : 1
            let widthAtTarget = aspect * targetRowHeight
            let gapIfNotFirst: CGFloat = (i > rowStart) ? horizontalGap : 0
            rowAccumWidth += widthAtTarget + gapIfNotFirst
            if rowAccumWidth >= containerWidth {
                flush(upToExclusive: i + 1, fillWidth: true)
            }
        }
        flush(upToExclusive: itemSizes.count, fillWidth: false)

        itemFrames = frames
        contentHeight = (y > contentInsets.top) ? (y - verticalGap + contentInsets.bottom) : 0
    }

    override var collectionViewContentSize: NSSize {
        NSSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var out: [NSCollectionViewLayoutAttributes] = []
        for i in 0..<itemFrames.count where itemFrames[i].intersects(rect) {
            let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
            a.frame = itemFrames[i]
            out.append(a)
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, indexPath.item < itemFrames.count else { return nil }
        let a = NSCollectionViewLayoutAttributes(forItemWith: indexPath)
        a.frame = itemFrames[indexPath.item]
        return a
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != lastContainerWidth
    }
}
