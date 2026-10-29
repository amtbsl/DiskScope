import Foundation

final class ReleaseNetworkPolicy: NSObject, URLSessionTaskDelegate {
    static func acceptsResponse(url: URL?, status: Int) -> Bool { url == ProjectRelease.api && status == 200 }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AppVersion: Comparable {
    let components: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

struct ProjectRelease {
    let tag: String
    let version: AppVersion
    let page: URL
    static let api = URL(string: "https://api.github.com/repos/amtbsl/DiskScope/releases/latest")!
    static let releases = URL(string: "https://github.com/amtbsl/DiskScope/releases")!
    static func parse(_ data: Data) throws -> ProjectRelease {
        struct Payload: Decodable { let tag_name: String; let html_url: String; let draft: Bool; let prerelease: Bool }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease, let version = AppVersion(payload.tag_name),
              let page = URL(string: "https://github.com/amtbsl/DiskScope/releases/tag/" + payload.tag_name),
              payload.html_url == page.absoluteString else {
            throw NSError(domain: "DiskScope.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: "GitHub returned an invalid release response."])
        }
        return ProjectRelease(tag: payload.tag_name, version: version, page: page)
    }
    static func fetch(completion: @escaping (Result<ProjectRelease, Error>) -> Void) {
        var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DiskScope/1.1.0", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: ReleaseNetworkPolicy(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error = error { completion(.failure(error)); return }
            guard let response = response as? HTTPURLResponse, ReleaseNetworkPolicy.acceptsResponse(url:response.url,status:response.statusCode), let data = data, data.count <= 2_000_000 else {
                completion(.failure(NSError(domain: "DiskScope.Updates", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not check GitHub for updates. You can open the project's Releases page and try again later."])))
                return
            }
            completion(Result { try parse(data) })
        }.resume()
    }
}

final class SearchRequestGate {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var resultGeneration: UInt64?
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; generation &+= 1; resultGeneration = nil; return generation }
    func invalidate() { _ = next() }
    func isCurrent(_ value: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return value == generation }
    @discardableResult func publishResults(for value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value == generation else { return false }
        resultGeneration = value; return true
    }
    func canActivateResults() -> Bool { lock.lock(); defer { lock.unlock() }; return resultGeneration == generation }
}
