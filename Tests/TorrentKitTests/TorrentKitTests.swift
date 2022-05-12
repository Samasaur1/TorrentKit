import XCTest
@testable import TorrentKit

final class TorrentKitTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        let tf = try TorrentFile(fromContentsOf: .init(fileURLWithPath: "/Users/sam/Downloads/ubuntu-22.04-desktop-amd64.iso.torrent"))
        dump(tf)
        print(tf.infoHash)
        //2c6b68 58 d6 1d a9 54 3d 42
        String.init(bytes: tf.infoHash, encoding: .ascii)
    }
}
