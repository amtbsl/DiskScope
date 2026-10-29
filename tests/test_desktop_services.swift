import Foundation

@main struct DesktopServiceTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        check(AppVersion("v1.10.0")! > AppVersion("1.9.9")!, "semantic numeric comparison")
        check(AppVersion("1.1.0")! == AppVersion("v1.1.0")!, "version tag prefix")
        check(AppVersion("1.1.0-beta") == nil, "stable versions only")
        check(AppVersion("1.1.0/evil") == nil, "no path injection in tag")
        check(AppVersion("1.1") == nil, "require three version components")
        let good = Data("{\"tag_name\":\"v1.2.0\",\"html_url\":\"https://github.com/amtbsl/DiskScope/releases/tag/v1.2.0\",\"draft\":false,\"prerelease\":false}".utf8)
        let release = try ProjectRelease.parse(good)
        check(release.version > AppVersion("1.1.0")!, "new release recognized")
        check(release.page.absoluteString == "https://github.com/amtbsl/DiskScope/releases/tag/v1.2.0", "fixed project release page")
        for invalid in [
            "{\"tag_name\":\"v1.2.0\",\"html_url\":\"https://evil.example/release\",\"draft\":false,\"prerelease\":false}",
            "{\"tag_name\":\"v1.2.0\",\"html_url\":\"https://github.com/amtbsl/DiskScope/releases/tag/v1.2.0\",\"draft\":false,\"prerelease\":true}",
            "not-json"
        ] {
            do { _ = try ProjectRelease.parse(Data(invalid.utf8)); check(false, "reject invalid/foreign/prerelease response") } catch {}
        }
        check(ReleaseNetworkPolicy.acceptsResponse(url: ProjectRelease.api, status: 200), "accept fixed successful endpoint")
        check(!ReleaseNetworkPolicy.acceptsResponse(url: URL(string:"https://evil.example/releases"), status: 200), "reject redirected response origin")
        check(!ReleaseNetworkPolicy.acceptsResponse(url: ProjectRelease.api, status: 302), "reject redirect status")
        let policy = ReleaseNetworkPolicy(), session = URLSession(configuration:.ephemeral)
        let task = session.dataTask(with:ProjectRelease.api)
        let redirect = HTTPURLResponse(url:ProjectRelease.api,statusCode:302,httpVersion:nil,headerFields:nil)!
        var redirected = true
        policy.urlSession(session, task:task, willPerformHTTPRedirection:redirect, newRequest:URLRequest(url:URL(string:"https://evil.example/releases")!)) { redirected = $0 != nil }
        check(!redirected, "delegate rejects redirects before transmission")
        session.invalidateAndCancel()
        let requests = SearchRequestGate()
        let first = requests.next()
        check(!requests.canActivateResults(), "typing cannot open results before any response")
        check(requests.publishResults(for: first) && requests.canActivateResults(), "only published current results can open")
        let second = requests.next()
        check(!requests.canActivateResults(), "new query immediately invalidates previously selected file")
        check(!requests.publishResults(for: first), "late prior query cannot reactivate stale selection")
        check(requests.publishResults(for: second) && requests.canActivateResults(), "new response activates current selection")
        check(!requests.isCurrent(first) && requests.isCurrent(second), "discard stale quick-search response")
        requests.invalidate()
        check(!requests.isCurrent(second), "closing panel discards pending response")
        print("PASS: desktop version/update validation, fixed origin and stale quick-search responses")
    }
}
