import AppKit

enum AuditClipboard {
    /// Called only after a user-requested snapshot has passed verification.
    /// Preparing the item first preserves the clipboard on empty/invalid export.
    /// No existing clipboard contents are read or retained by Cat Run.
    static func copy(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        guard !text.isEmpty else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}
