import AppKit

/// A markdown table in the transcript: a hairline-framed card like code
/// blocks, a tinted header row, hairline rules between rows, and cells that
/// render inline markdown. Cells wrap at `maxCellWidth`; a table wider than
/// the column scrolls sideways instead of squeezing its columns.
final class TableBlockView: Surface {
    static let maxCellWidth: CGFloat = 280
    private static let cellInsets = NSSize(width: 12, height: 7)

    private let scroll = NSScrollView()
    private let grid: TableGridView
    private var heightConstraint: NSLayoutConstraint!

    init(table: MD.Table, source: String) {
        grid = TableGridView(table: table)
        super.init(nil, radius: 10, stroke: T.borderL2)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        setAccessibilityRole(.table)
        setAccessibilityLabel("Table, \(table.header.count) columns, \(table.rows.count) rows")

        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false // else the clip view paints the body rows
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .allowed
        scroll.documentView = grid
        addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: grid.naturalSize.height)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
        // The grid covers the card, so draw the hairline frame above it.
        addStrokeOverlay()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Fill the card when narrow (rules run edge to edge); keep the
        // natural width when wide, so it scrolls.
        let natural = grid.naturalSize
        let width = max(natural.width, scroll.contentSize.width)
        if grid.frame.size != NSSize(width: width, height: natural.height) {
            grid.frame = NSRect(x: 0, y: 0, width: width, height: natural.height)
        }
        if heightConstraint.constant != natural.height { heightConstraint.constant = natural.height }
    }

    /// Cells laid out by hand: column width = widest cell (capped), row
    /// height = tallest cell. Drawn rules need exact row edges, which
    /// NSGridView doesn't expose.
    final class TableGridView: NSView {
        override var isFlipped: Bool { true }
        private var cellViews: [[NSTextField]] = []
        private var columnWidths: [CGFloat] = []
        private var rowHeights: [CGFloat] = []
        private(set) var naturalSize: NSSize = .zero

        init(table: MD.Table) {
            super.init(frame: .zero)
            let allRows = [table.header] + table.rows
            for (r, row) in allRows.enumerated() {
                var views: [NSTextField] = []
                for (c, text) in row.enumerated() {
                    let field = NSTextField(wrappingLabelWithString: "")
                    // Alignment must live in the string: a field's `alignment`
                    // is ignored once it holds attributed text.
                    let styled = NSMutableAttributedString(attributedString:
                        MD.renderInline(text, fontSize: 13, weight: r == 0 ? .semibold : .regular))
                    let para = NSMutableParagraphStyle()
                    para.alignment = table.alignments[c]
                    styled.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: styled.length))
                    field.attributedStringValue = styled
                    field.isSelectable = true
                    field.drawsBackground = false
                    field.preferredMaxLayoutWidth = TableBlockView.maxCellWidth
                    addSubview(field)
                    views.append(field)
                }
                cellViews.append(views)
            }
            measure()
        }
        required init?(coder: NSCoder) { fatalError() }

        private func measure() {
            let inset = TableBlockView.cellInsets
            let columns = cellViews.first?.count ?? 0
            columnWidths = Array(repeating: 0, count: columns)
            for row in cellViews {
                for (c, f) in row.enumerated() {
                    // Measure at unlimited width: a wrapping field's intrinsic
                    // width runs a few points short and wraps the last letter.
                    let natural = f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width ?? 0
                    columnWidths[c] = max(columnWidths[c], min(ceil(natural), TableBlockView.maxCellWidth))
                }
            }
            rowHeights = cellViews.map { row in
                row.enumerated().map { c, f -> CGFloat in
                    f.preferredMaxLayoutWidth = columnWidths[c]
                    return ceil(f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: columnWidths[c],
                                                                   height: .greatestFiniteMagnitude)).height ?? 0)
                }.max() ?? 0
            }
            naturalSize = NSSize(width: columnWidths.reduce(0, +) + CGFloat(columns) * inset.width * 2,
                                 height: rowHeights.reduce(0, +) + CGFloat(rowHeights.count) * inset.height * 2)
        }

        override func layout() {
            super.layout()
            let inset = TableBlockView.cellInsets
            var y: CGFloat = 0
            for (r, row) in cellViews.enumerated() {
                var x: CGFloat = 0
                for (c, f) in row.enumerated() {
                    f.frame = NSRect(x: x + inset.width, y: y + inset.height,
                                     width: columnWidths[c], height: rowHeights[r])
                    x += columnWidths[c] + inset.width * 2
                }
                y += rowHeights[r] + inset.height * 2
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            // Paint the whole body: left transparent, the scroll view's layer
            // shows through as black.
            T.bgBase.setFill()
            bounds.fill()
            guard let first = rowHeights.first else { return }
            let inset = TableBlockView.cellInsets
            let headerHeight = first + inset.height * 2
            T.codeBlockBanner.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
            T.borderL2.setFill()
            let hairline = 1 / (window?.backingScaleFactor ?? 2)
            var y = headerHeight
            for h in rowHeights.dropFirst() {
                NSRect(x: 0, y: y - hairline, width: bounds.width, height: hairline).fill()
                y += h + inset.height * 2
            }
        }
    }
}
