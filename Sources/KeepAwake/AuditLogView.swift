import AppKit
import KeepAwakeCore

/// Only this page scrolls. Native floating group rows keep the current date visible.
final class AuditLogView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case date(String)
        case event(AuditEvent)
    }
    var onCopyRequested: ((@escaping ([AuditEvent], String?) -> Void) -> Void)?
    private let pasteboard: NSPasteboard
    private let heading = AuditLogView.label("Activity", size: 15)
    private let copy = FlatButton("Copy logs", size: 13, dimWhenDisabled: true)
    private var copyRequest: UUID?
    private var feedbackReset: DispatchWorkItem?
    private var logsAvailable = false
    private var locale = Locale.current
    private var timeZone = TimeZone.current
    private let empty = AuditLogView.label("No activity logged yet.", size: 13)
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
    private var rows: [Row] = []
    private var events: [AuditEvent] = []
    private var lastColumnWidth: CGFloat = 0
    private var maximumTimestampWidth: CGFloat = 0
    private var formatContext = ""
    private var timeFormatter = DateFormatter()

    override convenience init(frame frameRect: NSRect) {
        self.init(frame: frameRect, pasteboard: .general)
    }
    init(frame frameRect: NSRect, pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init(frame: frameRect)
        copy.identifier = NSUserInterfaceItemIdentifier("copy-logs")
        copy.toolTip = "Copy all retained activity as text."
        copy.onClick = { [weak self] in self?.requestCopy() }
        heading.identifier = NSUserInterfaceItemIdentifier("logs-heading")
        empty.identifier = NSUserInterfaceItemIdentifier("logs-empty")
        scroll.identifier = NSUserInterfaceItemIdentifier("logs-scroll")
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.borderType = .noBorder
        scroll.backgroundColor = AppPalette.background
        scroll.drawsBackground = true
        scroll.scrollerKnobStyle = .light
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = AppPalette.background
        table.identifier = NSUserInterfaceItemIdentifier("logs-table")
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = AppPalette.background
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.floatsGroupRows = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        column.minWidth = 0
        column.maxWidth = 10_000
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        scroll.documentView = table
        [heading, copy, scroll, empty].forEach(addSubview)
        render(events: [], error: nil)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    deinit { feedbackReset?.cancel() }

    private func requestCopy() {
        guard copyRequest == nil, logsAvailable, !events.isEmpty else { return }
        feedbackReset?.cancel()
        let request = UUID()
        copyRequest = request
        copy.title = "Copying…"
        copy.isEnabled = false
        let completion: ([AuditEvent], String?) -> Void = { [weak self] events, error in
            guard let self, self.copyRequest == request else { return }
            self.copyRequest = nil
            self.render(events: events, error: error, locale: self.locale, timeZone: self.timeZone)
            guard error == nil, !events.isEmpty else {
                self.copy.title = "Copy logs"
                return
            }
            let text = AuditLogText.string(events: events, locale: self.locale, timeZone: self.timeZone)
            self.copy.title = AuditClipboard.copy(text, to: self.pasteboard) ? "Copied" : "Try again"
            self.copy.toolTip = self.copy.title == "Copied" ? "All retained activity was copied." : "Could not copy activity. Try again."
            let reset = DispatchWorkItem { [weak self] in
                self?.copy.title = "Copy logs"
                self?.copy.toolTip = "Copy all retained activity as text."
            }
            self.feedbackReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
        }
        if let onCopyRequested { onCopyRequested(completion) }
        else { completion(events, nil) }
    }

    func scrollToNewest() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func render(events: [AuditEvent], error: String?, locale: Locale = .current,
                timeZone: TimeZone = .current) {
        self.locale = locale
        self.timeZone = timeZone
        logsAvailable = error == nil
        copy.isEnabled = logsAvailable && !events.isEmpty && copyRequest == nil
        let newContext = "\(locale.identifier)|\(timeZone.identifier)"
        let changedContext = formatContext != newContext
        formatContext = newContext
        timeFormatter.locale = locale
        timeFormatter.timeZone = timeZone
        // Seconds are useful in an audit; the running countdown remains hours/minutes only.
        // Include the event's zone to distinguish a repeated hour when daylight saving ends.
        timeFormatter.dateFormat = "HH:mm:ss z"
        // The store supplies newest recorded activity first. A clock correction
        // must not reorder what happened; a repeated date heading is intentional.
        if changedContext || events.map(\.id) != self.events.map(\.id) || error != nil {
            self.events = events
            maximumTimestampWidth = events.map { AuditLogRow.measuredTimeWidth(timeFormatter.string(from: $0.date)) }.max() ?? 0
            rows.removeAll(keepingCapacity: true)
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            calendar.timeZone = timeZone
            let dateFormatter = DateFormatter()
            dateFormatter.locale = locale
            dateFormatter.timeZone = timeZone
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .none
            var previousDay: Date?
            for event in events {
                let day = calendar.startOfDay(for: event.date)
                if day != previousDay {
                    rows.append(.date(dateFormatter.string(from: event.date)))
                    previousDay = day
                }
                rows.append(.event(event))
            }
            table.reloadData()
        }
        empty.stringValue = error ?? "No activity logged yet."
        empty.isHidden = error == nil && !events.isEmpty
        scroll.isHidden = !empty.isHidden
        needsLayout = true
    }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 0, y: 3, width: max(0, bounds.width - 100), height: 23)
        copy.frame = NSRect(x: bounds.width - 86, y: 0, width: 86, height: 30)
        scroll.frame = NSRect(x: 0, y: 34, width: bounds.width, height: max(0, bounds.height - 34))
        empty.frame = NSRect(x: 0, y: 42, width: bounds.width,
                             height: max(0, bounds.height - 42))
        let width = scroll.contentSize.width
        if abs(lastColumnWidth - width) > 0.5 {
            lastColumnWidth = width
            column.width = width
            // A height-change notification animates from the previous (sometimes
            // not-yet-sized) column. Rebuild synchronously so opening and resizing
            // never leave tall blank rows or temporarily overlapping entries.
            table.reloadData()
        }
    }

    private var timestampWidth: CGFloat {
        // One column width for the entire snapshot, including a DST transition.
        // Leave room for the message even with a long localized zone label.
        min(maximumTimestampWidth, max(1, column.width * 0.5))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .date = rows[row] { return true }
        return false
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .date: return 26
        case .event(let event):
            return AuditLogRow.height(time: timeFormatter.string(from: event.date), message: event.message, width: column.width, timeWidth: timestampWidth)
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .date(let title):
            let id = NSUserInterfaceItemIdentifier("log-date")
            let view = table.makeView(withIdentifier: id, owner: self) as? AuditDateHeader ?? AuditDateHeader()
            view.identifier = id; view.setTitle(title)
            return view
        case .event(let event):
            let id = NSUserInterfaceItemIdentifier("log-event")
            let view = table.makeView(withIdentifier: id, owner: self) as? AuditLogRow ?? AuditLogRow()
            view.identifier = id
            view.set(time: timeFormatter.string(from: event.date), message: event.message, timeWidth: timestampWidth)
            return view
        }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        view.backgroundColor = AppPalette.background
        return view
    }

    fileprivate static func label(_ text: String, size: CGFloat) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = AppWindow.font(size)
        view.textColor = AppPalette.foreground
        view.isSelectable = false
        return view
    }
}

private final class AuditDateHeader: FlippedView {
    private let label = AuditLogView.label("", size: 13)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.identifier = NSUserInterfaceItemIdentifier("log-date-label")
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func setTitle(_ text: String) { label.stringValue = text }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 2, width: bounds.width - 6, height: 21)
    }
    override func draw(_ dirtyRect: NSRect) {
        AppPalette.background.setFill(); bounds.fill()
        AppPalette.foreground.withAlphaComponent(0.30).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

private final class AuditLogRow: FlippedView {
    private let time = AuditLogView.label("", size: 13)
    private let message = AuditLogView.label("", size: 13)
    private static let gap: CGFloat = 8
    private static let verticalPadding: CGFloat = 3
    private var timestampWidth: CGFloat = 0
    static func measuredTimeWidth(_ time: String) -> CGFloat {
        // Keep the timestamp and its timezone on one line instead of forcing
        // every short entry to inherit a second line of height.
        ceil((time as NSString).size(withAttributes: [.font: AppWindow.font(13)]).width) + 8
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        time.identifier = NSUserInterfaceItemIdentifier("log-time")
        message.identifier = NSUserInterfaceItemIdentifier("log-message")
        addSubview(time); addSubview(message)
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func set(time: String, message: String, timeWidth: CGFloat) {
        self.time.stringValue = time
        self.message.stringValue = message
        self.timestampWidth = timeWidth
        needsLayout = true
    }
    static func height(time: String, message: String, width: CGFloat, timeWidth: CGFloat) -> CGFloat {
        let available = max(1, width - timeWidth - gap - 6)
        func measured(_ text: String, width: CGFloat) -> CGFloat {
            let bounds = (text as NSString).boundingRect(with: NSSize(width: max(1, width - 4), height: 100_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: AppWindow.font(13)])
            return ceil(bounds.height) + 2
        }
        return max(20, max(measured(message, width: available), measured(time, width: timeWidth))) + verticalPadding * 2
    }
    override func layout() {
        super.layout()
        let timeWidth = timestampWidth
        time.frame = NSRect(x: 0, y: Self.verticalPadding, width: timeWidth, height: bounds.height - Self.verticalPadding * 2)
        message.frame = NSRect(x: timeWidth + Self.gap, y: Self.verticalPadding,
                               width: max(1, bounds.width - timeWidth - Self.gap - 6),
                               height: bounds.height - Self.verticalPadding * 2)
    }
}
