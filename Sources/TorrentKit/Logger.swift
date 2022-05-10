//
//  File.swift
//
//
//  Created by Sam Gauck on 5/2/22.
//

import Foundation

public struct Logger {
    public struct LogType: OptionSet {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        static let peerDataParsing              = LogType(rawValue: 1 << 0)
        static let stateChanges                 = LogType(rawValue: 1 << 1)
        static let listeningSocket              = LogType(rawValue: 1 << 2)
        static let trackerRequests              = LogType(rawValue: 1 << 3)
        static let outgoingSocketConnections    = LogType(rawValue: 1 << 4)
        static let verifyingPieces              = LogType(rawValue: 1 << 5)
        static let peerSocket                   = LogType(rawValue: 1 << 6)
        static let peerSocketDetailed           = LogType(rawValue: 1 << 7)
        static let bitfields                    = LogType(rawValue: 1 << 7)

        static let all: LogType = [.peerDataParsing, .stateChanges, .listeningSocket, .trackerRequests, .outgoingSocketConnections, .verifyingPieces, .peerSocket, .peerSocketDetailed, .bitfields]
    }

    private let allowedLogTypes: LogType

    public init(_ allowedTypes: LogType) {
        self.allowedLogTypes = allowedTypes
    }

    func log(_ msg: String, type: LogType) {
        if allowedLogTypes.contains(type) {
            print(msg)
        }
    }
}
