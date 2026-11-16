import Foundation

/// Finds the `.emlx` file of a message inside `~/Library/Mail/V10`.
///
/// Layout: `<root>/<account id>/<mailbox>.mbox/<store id>/Data/.../Messages/<ROWID>.emlx`.
/// A nested mailbox sits inside its parent's `.mbox` folder. The middle folders come from the ROWID digits and
/// differ by version, so the locator tries the likely ones first and then searches the mailbox's `Data` folder.
struct EmlxLocator: Sendable {
    let root: URL

    struct Found: Equatable {
        let url: URL
        /// A `.partial.emlx` file: Mail has not downloaded the whole message.
        let partial: Bool
    }

    func find(accountId: String, mailbox path: String, rowid: String) -> Found? {
        let fileManager = FileManager.default
        var folder = root.appendingPathComponent(accountId, isDirectory: true)
        for part in path.split(separator: "/") {
            folder.appendPathComponent("\(part).mbox", isDirectory: true)
        }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return nil }
        let stores = entries.filter { !$0.hasPrefix(".") && !$0.hasSuffix(".mbox") }.sorted()
        for store in stores {
            let data = folder.appendingPathComponent(store).appendingPathComponent("Data", isDirectory: true)
            if let found = guess(in: data, rowid: rowid) ?? search(in: data, rowid: rowid) { return found }
        }
        return nil
    }

    private func check(_ folder: URL, rowid: String) -> Found? {
        let full = folder.appendingPathComponent("\(rowid).emlx")
        if FileManager.default.fileExists(atPath: full.path) { return Found(url: full, partial: false) }
        let partial = folder.appendingPathComponent("\(rowid).partial.emlx")
        if FileManager.default.fileExists(atPath: partial.path) { return Found(url: partial, partial: true) }
        return nil
    }

    /// The likely folders: `Data/Messages`, and the thousands digits of the ROWID as folders (reversed, or as written).
    private func guess(in data: URL, rowid: String) -> Found? {
        var folders = [data.appendingPathComponent("Messages", isDirectory: true)]
        if let number = Int(rowid), number >= 1000 {
            let digits = String(number / 1000).map(String.init)
            for order in [Array(digits.reversed()), digits] {
                var folder = data
                for digit in order { folder.appendPathComponent(digit, isDirectory: true) }
                folders.append(folder.appendingPathComponent("Messages", isDirectory: true))
            }
        }
        for folder in folders {
            if let found = check(folder, rowid: rowid) { return found }
        }
        return nil
    }

    /// Walks the `Data` folder. It skips the folders of nested mailboxes.
    private func search(in data: URL, rowid: String) -> Found? {
        guard
            let walker = FileManager.default.enumerator(
                at: data, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return nil }
        var partial: Found?
        for case let url as URL in walker {
            if url.pathExtension == "mbox" {
                walker.skipDescendants()
                continue
            }
            switch url.lastPathComponent {
            case "\(rowid).emlx": return Found(url: url, partial: false)
            case "\(rowid).partial.emlx": partial = partial ?? Found(url: url, partial: true)
            default: break
            }
        }
        return partial
    }
}
