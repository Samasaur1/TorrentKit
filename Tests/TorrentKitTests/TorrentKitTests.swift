import XCTest
@testable import TorrentKit

final class TorrentKitTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        let tf = try TorrentFile(fromContentsOf: .init(fileURLWithPath: "/Users/sam/Downloads/summer-wars_archive.torrent"))
        dump(tf)
    }
}
