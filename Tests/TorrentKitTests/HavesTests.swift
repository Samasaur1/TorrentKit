//
//  HavesTests.swift
//  
//
//  Created by Sam Gauck on 5/9/22.
//

import XCTest
@testable import TorrentKit

class HavesTests: XCTestCase {
    func testBitfield() {
        var data = Data()
        for _ in 0..<100 {
            data.append(.random(in: 0...255))
        }
        data.append(0b11110000)
        let haves = TorrentDownload.Haves(fromBitfield: data, length: 804)
        let repacked = haves.repack()
        XCTAssertEqual(data, repacked)
    }
}
