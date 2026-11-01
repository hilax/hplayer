import Foundation

/// Shared, session-scoped account information for the library and settings tabs.
@MainActor
final class P115AccountInfoStore: ObservableObject {
    @Published private(set) var status: P115Status?
    @Published private(set) var quota: QuotaResponse?
    @Published private(set) var statusError = ""
    @Published private(set) var loadingStatus = false

    private(set) var sessionID: UUID?
    private var statusTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var statusRequestID = UUID()
    private var quotaRequestID = UUID()
    private var statusUpdatedAt: Date?
    private var quotaUpdatedAt: Date?
    private var statusAttemptedAt: Date?
    private var quotaAttemptedAt: Date?

    private let fetchStatus: (Direct115Client) async throws -> P115Status
    private let fetchQuota: (Direct115Client) async throws -> QuotaResponse
    private let now: () -> Date
    private let freshness: TimeInterval
    private let retryDelay: TimeInterval

    init(fetchStatus: @escaping (Direct115Client) async throws -> P115Status = { try await $0.user() },
         fetchQuota: @escaping (Direct115Client) async throws -> QuotaResponse = { try await $0.quota() },
         now: @escaping () -> Date = { Date() }, freshness: TimeInterval = 300, retryDelay: TimeInterval = 30) {
        self.fetchStatus = fetchStatus
        self.fetchQuota = fetchQuota
        self.now = now
        self.freshness = freshness
        self.retryDelay = retryDelay
    }

    func status(for session: UUID) -> P115Status? { sessionID == session ? status : nil }
    func quota(for session: UUID) -> QuotaResponse? { sessionID == session ? quota : nil }
    func error(for session: UUID) -> String { sessionID == session ? statusError : "" }
    func isLoading(for session: UUID) -> Bool { sessionID == session && loadingStatus }

    /// The requests outlive a tab's view. Repeated callers share the same in-flight work.
    func refreshIfNeeded(session: UUID, client: Direct115Client?) async {
        guard !Task.isCancelled else { return }
        if sessionID != session { reset(for: session) }
        guard let client else {
            if status != nil || quota != nil || statusTask != nil || quotaTask != nil || !statusError.isEmpty {
                clearCurrentSessionData()
            }
            return
        }
        let date = now()
        if statusTask == nil && shouldRefresh(updated: statusUpdatedAt, attempted: statusAttemptedAt, at: date) {
            startStatusRequest(client: client, session: session, at: date)
        }
        if quotaTask == nil && shouldRefresh(updated: quotaUpdatedAt, attempted: quotaAttemptedAt, at: date) {
            startQuotaRequest(client: client, session: session, at: date)
        }
        let pendingStatus = statusTask
        let pendingQuota = quotaTask
        await pendingStatus?.value
        await pendingQuota?.value
    }

    /// A successful explicit connection check should also update both tabs.
    func record(_ value: P115Status, for session: UUID) {
        guard sessionID == session else { return }
        statusTask?.cancel()
        statusTask = nil
        statusRequestID = UUID()
        loadingStatus = false
        status = value
        statusError = ""
        statusUpdatedAt = now()
        statusAttemptedAt = statusUpdatedAt
    }

    /// Screenshot fixtures provide their own data and never contact 115.
    func seed(session: UUID, status: P115Status?, quota: QuotaResponse?) {
        guard sessionID != session else { return }
        reset(for: session)
        self.status = status
        self.quota = quota
        statusUpdatedAt = status == nil ? nil : now()
        quotaUpdatedAt = quota == nil ? nil : now()
    }

    private func shouldRefresh(updated: Date?, attempted: Date?, at date: Date) -> Bool {
        if let updated, date.timeIntervalSince(updated) < freshness { return false }
        if let attempted, date.timeIntervalSince(attempted) < retryDelay { return false }
        return true
    }

    private func reset(for session: UUID) {
        clearCurrentSessionData()
        sessionID = session
    }

    private func clearCurrentSessionData() {
        statusTask?.cancel()
        quotaTask?.cancel()
        statusTask = nil
        quotaTask = nil
        statusRequestID = UUID()
        quotaRequestID = UUID()
        status = nil
        quota = nil
        statusError = ""
        loadingStatus = false
        statusUpdatedAt = nil
        quotaUpdatedAt = nil
        statusAttemptedAt = nil
        quotaAttemptedAt = nil
    }

    private func startStatusRequest(client: Direct115Client, session: UUID, at date: Date) {
        let request = UUID()
        statusRequestID = request
        statusAttemptedAt = date
        loadingStatus = true
        let fetch = fetchStatus
        statusTask = Task { [weak self] in
            defer {
                if let self, self.statusRequestID == request {
                    self.loadingStatus = false
                    self.statusTask = nil
                }
            }
            do {
                let value = try await fetch(client)
                guard let self, !Task.isCancelled, self.sessionID == session, self.statusRequestID == request else { return }
                self.status = value
                self.statusError = ""
                self.statusUpdatedAt = self.now()
            } catch {
                guard let self, !Task.isCancelled, self.sessionID == session, self.statusRequestID == request,
                      !(error is CancellationError) else { return }
                self.statusError = error.localizedDescription
            }
        }
    }

    private func startQuotaRequest(client: Direct115Client, session: UUID, at date: Date) {
        let request = UUID()
        quotaRequestID = request
        quotaAttemptedAt = date
        let fetch = fetchQuota
        quotaTask = Task { [weak self] in
            defer {
                if let self, self.quotaRequestID == request { self.quotaTask = nil }
            }
            do {
                let value = try await fetch(client)
                guard let self, !Task.isCancelled, self.sessionID == session, self.quotaRequestID == request else { return }
                self.quota = value
                self.quotaUpdatedAt = self.now()
            } catch {
                // Keep the last known capacity; the next eligible refresh retries it.
            }
        }
    }
}
