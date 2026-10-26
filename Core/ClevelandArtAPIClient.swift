import Foundation

/// Abstracts URLSession so network behavior can be tested without a network.
protocol HTTPDataLoading: Sendable {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoading {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

enum NetworkError: Error, LocalizedError, Equatable {
    case httpStatus(Int)
    case invalidResponse
    case decoding(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "The museum server responded with HTTP \(code)."
        case .invalidResponse: return "The museum server returned an unexpected response."
        case .decoding(let detail): return "The museum data could not be read (\(detail))."
        case .offline: return "You appear to be offline."
        }
    }

    /// Whether trying again later could plausibly succeed.
    var isTransient: Bool {
        switch self {
        case .httpStatus(let code): return code == 408 || code == 429 || (500...599).contains(code)
        case .offline: return true
        case .invalidResponse, .decoding: return false
        }
    }
}

/// Exponential backoff for transient failures.
struct RetryPolicy: Sendable {
    var maxAttempts = 3
    var baseDelay: Duration = .seconds(2)

    static let none = RetryPolicy(maxAttempts: 1, baseDelay: .zero)

    func run<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, Self.isTransient(error), !Task.isCancelled else { throw error }
                let delay = baseDelay * (1 << (attempt - 1))
                try await Task.sleep(for: delay)
                attempt += 1
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if let error = error as? NetworkError { return error.isTransient }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .internationalRoamingOff,
                 .dataNotAllowed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

/// Client for the Cleveland Museum of Art Open Access API
/// (https://openaccess-api.clevelandart.org/). No API key is required.
struct ClevelandArtAPIClient: Sendable {
    static let baseURL = URL(string: "https://openaccess-api.clevelandart.org/api/artworks/")!

    /// Only the fields the app uses. Keeps the highlight index to a few hundred KB.
    static let fields = [
        "id", "accession_number", "share_license_status", "is_highlight", "title", "tombstone",
        "creation_date", "creators", "culture", "technique", "type", "department", "creditline",
        "url", "description", "artlens_description", "did_you_know", "images",
    ]

    var loader: HTTPDataLoading
    var retry = RetryPolicy()
    var pageSize = 500

    init(loader: HTTPDataLoading = URLSession(configuration: .default), retry: RetryPolicy = RetryPolicy(), pageSize: Int = 500) {
        self.loader = loader
        self.retry = retry
        self.pageSize = pageSize
    }

    func listURL(scope: CollectionScope, skip: Int, limit: Int) -> URL {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if scope == .highlights {
            items.append(URLQueryItem(name: "highlight", value: "1"))
        }
        // `cc0` is a presence flag in this API; the license is re-checked client-side anyway.
        items.append(URLQueryItem(name: "cc0", value: nil))
        items.append(URLQueryItem(name: "has_image", value: "1"))
        items.append(URLQueryItem(name: "limit", value: String(limit)))
        items.append(URLQueryItem(name: "skip", value: String(skip)))
        items.append(URLQueryItem(name: "fields", value: Self.fields.joined(separator: ",")))
        components.queryItems = items
        return components.url!
    }

    struct Page: Sendable {
        var records: [CMARecord]
        var malformedCount: Int
        var total: Int?
    }

    func fetchPage(scope: CollectionScope, skip: Int, limit: Int) async throws -> Page {
        var request = URLRequest(url: listURL(scope: scope, skip: skip, limit: limit))
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await retry.run { try await load(request) }
        do {
            let response = try JSONDecoder().decode(CMAListResponse.self, from: data)
            let records = response.data.compactMap { $0 }
            return Page(records: records, malformedCount: response.data.count - records.count, total: response.info?.total)
        } catch {
            throw NetworkError.decoding(String(describing: error))
        }
    }

    /// Pages through the whole result set for a scope.
    func fetchAll(scope: CollectionScope, progress: (@Sendable (Int, Int?) -> Void)? = nil) async throws -> Page {
        var all: [CMARecord] = []
        var malformed = 0
        var total: Int?
        var skip = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(scope: scope, skip: skip, limit: pageSize)
            total = page.total ?? total
            all += page.records
            malformed += page.malformedCount
            let received = page.records.count + page.malformedCount
            skip += received
            progress?(skip, total)
            if received == 0 || received < pageSize { break }
            if let total, skip >= total { break }
        }
        return Page(records: all, malformedCount: malformed, total: total)
    }

    private func load(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await loader.fetchData(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw NetworkError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw NetworkError.httpStatus(http.statusCode) }
        return data
    }
}
