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

        public static let peerDataParsing              = LogType(rawValue: 1 << 0)
        public static let stateChanges                 = LogType(rawValue: 1 << 1)
        public static let listeningSocket              = LogType(rawValue: 1 << 2)
        public static let trackerRequests              = LogType(rawValue: 1 << 3)
        public static let outgoingSocketConnections    = LogType(rawValue: 1 << 4)
        public static let verifyingPieces              = LogType(rawValue: 1 << 5)
        public static let peerSocket                   = LogType(rawValue: 1 << 6)
        public static let peerSocketDetailed           = LogType(rawValue: 1 << 7)
        public static let bitfields                    = LogType(rawValue: 1 << 7)

        public static let socketConnections: LogType = [.listeningSocket, .outgoingSocketConnections]
        public static let all: LogType = [.peerDataParsing, .stateChanges, .listeningSocket, .trackerRequests, .outgoingSocketConnections, .verifyingPieces, .peerSocket, .peerSocketDetailed, .bitfields]
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
