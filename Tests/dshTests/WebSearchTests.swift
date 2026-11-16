import XCTest
@testable import DSHCore

final class WebSearchTests: XCTestCase {
    func testParsesDuckDuckGoResults() throws {
        let html = """
        <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fx%3D1&amp;rut=abc">Example &amp; <b>Co</b></a>
        <a class="result__snippet" href="#">First <b>snippet</b></a>
        <a rel="nofollow" class="result__a" href="https://example.org/b">Second</a>
        <a class="result__snippet" href="#">Second snippet</a>
        """
        let out = try WebText.parseResults(html: html, limit: 5)
        XCTAssertEqual(out, """
        1. Example & Co
           https://example.com/a?x=1
           First snippet

        2. Second
           https://example.org/b
           Second snippet
        """)
        XCTAssertEqual(try WebText.parseResults(html: html, limit: 1).components(separatedBy: "\n\n").count, 1)
        XCTAssertEqual(try WebText.parseResults(html: "<html></html>", limit: 5), "no results")
    }

    /// Opt-in live check (network): DSH_LIVE_SEARCH=1 swift test --filter WebSearchTests
    func testLiveSearchGoesThroughPinnedFetch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DSH_LIVE_SEARCH"] == "1")
        let out = try await WebText.search(query: "swift programming language", limit: 3)
        XCTAssertTrue(out.hasPrefix("1. "), out)
    }
}
