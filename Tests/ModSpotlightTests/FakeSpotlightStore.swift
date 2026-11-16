import AppleSauceCore
import Foundation

@testable import ModSpotlight

/// A spotlight store in memory. It records every call. It never runs mdfind and never reads the real file system.
final class FakeSpotlightStore: SpotlightStore, @unchecked Sendable {
    struct State {
        var paths: [String] = []
        /// What `search` reports as cut.
        var searchTruncated = false
        /// Details by path. A path without an entry counts as deleted.
        var files: [String: FileInfo] = [:]
        var searchDelay: Double = 0
        var calls: [String] = []
        var lastQuery: String?
        var lastFolder: String?
    }

    private let lock = NSLock()
    private var state: State

    init(_ state: State = State()) {
        self.state = state
    }

    func read<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private func write(_ body: (inout State) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&state)
    }

    func search(query: String, folder: String?) async throws -> SearchHits {
        write {
            $0.calls.append("search")
            $0.lastQuery = query
            $0.lastFolder = folder
        }
        let delay = read(\.searchDelay)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return SearchHits(paths: read(\.paths), truncated: read(\.searchTruncated))
    }

    func describe(path: String) async -> FileInfo? {
        write { $0.calls.append("describe") }
        return read { $0.files[path] }
    }
}

func fileInfo(_ path: String, kind: String = "PDF document", size: Int? = 1024) -> FileInfo {
    FileInfo(
        path: path, name: (path as NSString).lastPathComponent, kind: kind, size: size,
        modified: Date(timeIntervalSince1970: 1_700_000_000))
}
