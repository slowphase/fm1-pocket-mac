import Foundation

/// Fetches a URL. The app uses URLSession; tests inject a local fake server.
public protocol HTTPFetching: Sendable {
    /// the body and the HTTP status code
    func fetch(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionFetcher: HTTPFetching {
    public let session: URLSession
    public let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 60) {
        self.session = session
        self.timeout = timeout
    }

    public func fetch(_ url: URL) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 200)
    }
}

/// Decides when a download may start. Background downloads run at most `limit` (2) at a time, first come first
/// served. An interactive download (a firmware someone just pressed Play on) never waits behind them: it starts
/// at once, and a background download that is still queued can be promoted to interactive.
public actor DownloadScheduler {
    public enum Priority: Int, Sendable { case background, interactive }

    private struct Waiter {
        let tag: String
        let cont: CheckedContinuation<Void, Never>
    }

    public let limit: Int
    private var runningBackground = 0
    private var queue: [Waiter] = []
    private var grants: [String: Priority] = [:]
    /// the order downloads were allowed to start in (for tests and diagnostics)
    public private(set) var started: [String] = []

    public init(limit: Int = 2) { self.limit = max(1, limit) }

    public var queued: [String] { queue.map(\.tag) }

    /// Waits for a slot; returns the kind of slot granted, which must be handed back to `release`.
    public func acquire(tag: String, priority: Priority) async -> Priority {
        if priority == .interactive {
            started.append(tag)
            return .interactive
        }
        if runningBackground < limit {
            runningBackground += 1
            started.append(tag)
            return .background
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.append(Waiter(tag: tag, cont: c)) }
        return grants.removeValue(forKey: tag) ?? .background
    }

    public func release(_ granted: Priority) {
        guard granted == .background else { return }
        if !queue.isEmpty {
            let next = queue.removeFirst()          // the slot passes straight to the next in line
            grants[next.tag] = .background
            started.append(next.tag)
            next.cont.resume()
        } else {
            runningBackground -= 1
        }
    }

    /// Starts a queued background download now, as interactive. Does nothing if it is not queued.
    public func promote(tag: String) {
        guard let i = queue.firstIndex(where: { $0.tag == tag }) else { return }
        let w = queue.remove(at: i)
        grants[w.tag] = .interactive
        started.append(w.tag)
        w.cont.resume()
    }
}
