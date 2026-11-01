import Foundation

/// Owns a search response so a slower, older request cannot replace the latest query.
@MainActor
final class CloudSearchStore: ObservableObject {
    @Published private(set) var results: [P115File]
    @Published private(set) var searchedKeyword: String
    @Published private(set) var loading = false
    @Published private(set) var error = ""
    private var request = UUID()

    init(initialQuery: String = "", initialResults: [P115File] = []) {
        results = initialResults
        searchedKeyword = initialQuery
    }

    func invalidate(clearResults: Bool = false) {
        request = UUID()
        loading = false
        error = ""
        if clearResults { results = []; searchedKeyword = "" }
    }

    func search(_ query: String, lookup: (String) async throws -> [P115File]) async {
        guard !Task.isCancelled else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { invalidate(clearResults: true); return }
        let current = UUID()
        request = current
        loading = true
        error = ""
        defer { if request == current { loading = false } }
        do {
            let files = try await lookup(text)
            guard request == current, !Task.isCancelled else { return }
            results = files.filter { !$0.isDir && $0.isVideo }
            searchedKeyword = text
        } catch {
            guard request == current, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
