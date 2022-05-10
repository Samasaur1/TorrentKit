//
//  File 2.swift
//  
//
//  Created by Sam Gauck on 5/6/22.
//

import Foundation
import Dispatch
import BencodingKit
import Socket
import CryptoKit

public var DEBUG = true
public var SOCKETEE = false
public var MAX_PEER_CONNECTIONS = 30
public var logger = Logger([.stateChanges])

public actor TorrentDownload {
    private struct PeerData {
        let ip: String
        let port: Int32
        let peerID: Data

        init(from dict: [String: Any]) {
            logger.log("initting peerdata with dict \(dict)", type: .peerDataParsing)
            ip = dict["ip"] as! String
            port = Int32(dict["port"] as! Int)
            peerID = (dict["peer id"] as! String).hashify()
        }
    }
    public enum Status {
        case off, beginning, running, stopping
    }
    private class AvoidActorIsolation {
        private let shimPeerQueue = DispatchQueue(label: "com.gauck.sam.torrentkit.shim.queue.peer")
        private let shimHavesQueue = DispatchQueue(label: "com.gauck.sam.torrentkit.shim.queue.haves")

        var serverSocket: Socket!
        var shouldBeListening = false

        var socketOperationsShouldContinue = true

        private var _haves = Haves.empty(ofLength: 0)
        func _setHaves(_ haves: Haves) {
            shimHavesQueue.sync {
                _haves = haves
            }
        }
        func _getHaves() -> Haves {
            shimHavesQueue.sync {
                _haves
            }
        }
        func getHaves(idx: UInt32) -> Bool {
            shimHavesQueue.sync {
                _haves[idx]
            }
        }
        func setHaves(idx: UInt32, to newValue: Bool) {
            shimHavesQueue.sync {
                _haves[idx] = newValue
            }
        }
//        var haves: Haves {
//            get {
//                shimHavesQueue.sync {
//                    _haves
//                }
//            }
//            set {
//                shimHavesQueue.sync {
//                    _haves = newValue
//                }
//            }
//        }

        private var _peers: [PeerData] = []
        func newPeers(_ peers: [PeerData]) {
            shimPeerQueue.sync {
                self._peers.append(contentsOf: peers)
            }
        }
        func nextPeerForConnection() -> PeerData? {
            return shimPeerQueue.sync {
                guard self.connectedPeers < MAX_PEER_CONNECTIONS else {
                    return nil
                }
                guard !_peers.isEmpty else {
                    return nil
                }
                self.connectedPeers += 1
                return _peers.removeFirst()
            }
        }
        private var connectedPeers: Int = 0 {
            didSet {
                logger.log("Now at \(connectedPeers) connected peers", type: .peerSocket)
            }
        }
        func failedToConnectToPeer() {
            shimPeerQueue.sync {
                self.connectedPeers -= 1
            }
        }
//        func connectedToPeer() {
//            shimQueue.sync {
//                <#code#>
//            }
//        }
        func __connectedToPeer() {
            shimPeerQueue.sync {
                self.connectedPeers += 1
            }
        }
        func connectionToPeerClosed() {
            self.failedToConnectToPeer()
        }
    }
    struct /*The*/ Haves /*And The Have-Nots*/ {
        internal private(set) var arr: [Bool] = []
        let length: Int
        //This MUST NOT be a slice, but slices can be usable if wrapped in Data
        //  see https://forums.swift.org/t/is-this-a-flaw-in-data-design/12812
        init(fromBitfield bitfield: Data, length: Int) {
            for i in 0..<length {
                let byte = bitfield[i/8]
                let val = byte & (UInt8(0b10000000) >> (i % 8))
                arr.append(val != 0)
            }
            self.length = length
        }
        static func empty(ofLength length: Int) -> Haves {
            return Haves(fromBitfield: Data(repeating: 0, count: (length/8)+1), length: length)
        }
        subscript(index: Int) -> Bool {
            get {
                arr[index]
            }
            set {
                arr[index] = newValue
            }
        }
        subscript(index: UInt32) -> Bool {
            get {
                self[Int(index)]
            }
            set {
                self[Int(index)] = newValue
            }
        }

        func repack() -> Data {
            var data = Data()
            var currentByte = UInt8(0)
            var bitInByte = 7
            for val in arr {
                if bitInByte < 0 {
                    data.append(currentByte)
                    currentByte = 0
                    bitInByte = 7
                }
                guard val else {
                    bitInByte -= 1
                    continue
                }
                currentByte |= 1 << bitInByte
                bitInByte -= 1
            }
            if bitInByte > -1 {
                data.append(currentByte)
            }
            return data
        }
        func makeMessage() -> Data {
            let packed = repack()
            let msg = Data(from: UInt32(1 + packed.count).bigEndian) + [5] + packed
            return msg
        }

        func newPieces(fromOld old: Haves) -> [UInt32] {
//            var indices = [UInt32]()
//            zip(arr, old.arr).enumerated().filter { (idx, tup) in
//                let (newVal, oldVal) = tup
//                if newVal != oldVal {
//                    indices.append(UInt32(idx))
//                }
//            }
//            return indices
            var indices = [UInt32]()
            for i in 0..<arr.count {
                if arr[i] && !old.arr[i] {
                    indices.append(UInt32(i))
                }
            }
            return indices
        }

        var isComplete: Bool {
            !arr.contains(false)
        }

        var bitString: String {
            arr.map { $0 ? "1" : "0"}.joined(separator: "")
        }

        var percentComplete: Double {
            var successes = 0.0
            for val in arr {
                if val {
                    successes += 1
                }
            }
            return successes/Double(length)*100
        }
    }

    private let torrentFile: TorrentFile
    private let urlEncodedInfoHash: String
    private let peerID = "-SG0000-000000000000"
    private let length: Int
    private let handshake: Data

//    private let trackerQueue = DispatchQueue(label: "com.gauck.sam.torrentkit.tracker", attributes: .concurrent)
//    private var trackerTask: URLSessionDataTask? = nil
    private var trackerTask: Task<Void, Error>? = nil
    public private(set) var state: Status {
        didSet {
            logger.log("state went from \(oldValue) to \(state)", type: .stateChanges)
        }
    }
    private let peerQueue = DispatchQueue(label: "com.gauck.sam.torrentkit.queue.peer", attributes: .concurrent)
    private let writingQueue = DispatchQueue(label: "com.gauck.sam.torrentkit.queue.writing")
    private let listenQueue = DispatchQueue(label: "com.gauck.sam.torrentkit.queue.listen")
    private let peerManagementQueue = DispatchQueue(label: "com.gauck.sam.torrentkiy.queue.peermanagement")
    private let handle: FileHandle
    private let shim: AvoidActorIsolation = AvoidActorIsolation()
    private var serverSocket: Socket! {
        get {
            shim.serverSocket
        }
        set {
            shim.serverSocket = newValue
        }
    }
//    private nonisolated func acceptClientConnection() throws -> Socket {
//        let ss = await self.serverSocket
//        return try ss.acceptClientConnection()
//    }

    private var trackerID: String?
    private var peers: [PeerData] = [] {
        didSet {
            shim.newPeers(peers)
        }
    }
    private var interval: Int!
    private var port: Int32!
    private var shouldBeListening: Bool {
        get {
            shim.shouldBeListening
        }
        set {
            shim.shouldBeListening = newValue
        }
    }
    private var socketOperationsShouldContinue: Bool {
        get {
            shim.socketOperationsShouldContinue
        }
        set {
            shim.socketOperationsShouldContinue = newValue
        }
    }

    private var downloaded: Int = 0
    private var uploaded: Int = 0

    private func reportDownloaded(bytes: Int) {
        self.downloaded += bytes
    }
    private func reportUploaded(bytes: UInt32) {
        self.uploaded += Int(bytes)
    }

    public private(set) var completed: Bool

    public init(pathToTorrentFile url: URL) {
        //Swift complains if I say
//        self.torrentFile = torrentFile(fromContentsOf: url)
        let torrentFile = TorrentFile(fromContentsOf: url)
        precondition(torrentFile.singleFileMode != nil, "Multiple-file torrents are not yet supported")
        self.torrentFile = torrentFile
        self.length = torrentFile.length
        self.handshake = Data([19]) + "BitTorrent protocol".data(using: .ascii)! + Data(repeating: 0, count: 8) + torrentFile.infoHash + self.peerID.data(using: .ascii)!
        urlEncodedInfoHash = torrentFile.infoHash.map { byte in
            switch byte {
            case 126:
                return "~"
            case 46:
                return "."
            case 95:
                return "_"
            case 45:
                return "-"
            case let x where x >= 48 && x <= 57: // [0-9]
                //return Character(UnicodeScalar(x))
                return "\(x-48)"
            case let x where x >= 65 && x <= 90: //[A-Z]
                return String(Character(UnicodeScalar(x)))
            case let x where x >= 97 && x <= 122: //[a-z]
                return String(Character(UnicodeScalar(x)))
            default:
                return String(format: "%%%02x", byte)
                //equivalent to String(byte, radix: 16, uppercase: true) but with padding
            }
        }.joined(separator: "")
        state = .off

        func createOutputFileHandle() throws -> (FileHandle, Haves) {
            var haves = Haves.empty(ofLength: torrentFile.pieceCount)
            let path = URL(fileURLWithPath: "/tmp/\(torrentFile.singleFileMode!.name)")
            if FileManager.default.fileExists(atPath: path.path) {
                let handle = try FileHandle(forUpdating: path)
                try handle.seek(toOffset: 0)
                let length = torrentFile.pieceLength
                for i in 0..<torrentFile.pieceCount {
                    //if less than length bytes are available, read to the end of the file
                    guard let data = try handle.read(upToCount: length) else {
                        return (handle, haves)
                    }
                    let hash = Data(Insecure.SHA1.hash(data: data))
                    if hash == torrentFile.pieces[i] {
                        haves[i] = true
                    }
                }
                return (handle, haves)
            } else {
                FileManager.default.createFile(atPath: path.path, contents: nil)
                return (try FileHandle(forUpdating: path), haves)
            }
        }
        guard let (handle, haves) = try? createOutputFileHandle() else {
            print("Unable to create output file handle")
            fatalError()
        }
        self.completed = haves.isComplete
        print("Recovered \(haves.percentComplete, stringFormat: "%.2f")% of torrent download")
        self.handle = handle
        self.shim._setHaves(haves)
    }

    public func begin() {
////        Task {
////            await URLSession.shared.data(for: req)
////        }
//        trackerTask = URLSession.shared.dataTask(with: req) { data, response, error in
//            guard let response = response as? HTTPURLResponse else {
//                return
//            }
//            guard response.statusCode == 200 else {
//                print(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))
//                return
//            }
//            guard let data = data else {
//                return
//            }
//            print("200 OK, data valid")
//
//            guard let dict = try? Bencoding.object(from: data) else {
//                try! data.write(to: .init(fileURLWithPath: "/tmp/data.dat"))
//                fatalError("/tmp/data.dat")
//            }
//        }
//        trackerQueue.async {
//            while downloading {
//                sleep(1000000)
//            }
//        }
        precondition(state == .off)
        guard !completed else {
            print("Currently, once the torrent is complete, you cannot continue seeding")
            exit(0)
        }
        state = .beginning
        serverSocket = try! .create()
        if SOCKETEE {
            try! serverSocket.listen(on: 6882)
            self.port = 6881
            print("Advertising listen on 6881 but forced listen on 6882; use socketee 6881 localhost 6882 verbose")
        } else {
            listener: for _port in 6881...6889 {
                do {
                    try serverSocket.listen(on: _port)
                    self.port = Int32(_port)
                    logger.log("listening socket bound to port \(_port)", type: .listeningSocket)
                    break listener
                } catch {
                    if _port == 6889 {
                        //exhausted all ports
                        fatalError("Cannot bind to port")
                    }
                }
            }
        }
        shouldBeListening = true
        listenQueue.async {
            while self.shim.shouldBeListening {
                do {
                    logger.log("Waiting for incoming connection to socket", type: .listeningSocket)
                    let s = try self.shim.serverSocket.acceptClientConnection()
                    logger.log("Got incoming connection to socket from \(s.remoteHostname):\(s.remotePort)", type: .listeningSocket)
                    let handshake_buf = UnsafeMutablePointer<CChar>.allocate(capacity: 68)
                    defer {
                        handshake_buf.deallocate()
                    }
                    var data = Data()
                    let _ = try s.read(into: &data, bytes: 68)
                    let _infoHash = data[28..<48]
                    guard _infoHash == self.torrentFile.infoHash else {
                        logger.log("Incoming connection had infoHash \(_infoHash.hexStringEncoded()) but this download has infoHash \(self.torrentFile.infoHash.hexStringEncoded()); closing socket", type: .listeningSocket)
                        s.close()
                        return
                    }
                    let _peerID = data[48...]
                    logger.log("Got peer ID \(_peerID.hexStringEncoded())", type: .listeningSocket)
                    try s.write(from: self.handshake)
                    self.shim.__connectedToPeer()
                    self.addPeerSocket(s)
                } catch {}
            }
        }
        Task {
            let req = buildTrackerRequest(uploaded: 0, downloaded: 0, left: self.length, event: "started")

            logger.log("Making initial URLRequest", type: .trackerRequests)
            let (data, response) = try await URLSession.shared.data(for: req)

            guard let response = response as? HTTPURLResponse else {
                fatalError("Starting request had invalid response")
            }
            guard response.statusCode == 200 else {
                try? data.write(to: .init(fileURLWithPath: "/tmp/debug.dat"))
                dump(data)
                dump(response)
                fatalError("Starting request had valid response with non-OK error code")
            }

            guard let obj = try? Bencoding.object(from: data), let dict = obj as? [String: Any] else {
                try! data.write(to: .init(fileURLWithPath: "/tmp/start.dat"))
                fatalError("/tmp/start.dat")
            }

            if let reason = dict["failure reason"] {
                print("Failure: \(reason)")
                return
            }

            guard let interval = dict["interval"] as? Int else {
                fatalError("Missing fields")
            }
            self.interval = interval

            logger.log("Starting intermittent tracker task", type: .trackerRequests)
            trackerTask = Task {
                logger.log("Intermittent tracker task has begun!", type: .trackerRequests)
                while true {
                    logger.log("Tracker task will wait", type: .trackerRequests)
                    try await Task.sleep(nanoseconds: UInt64(self.interval) * NSEC_PER_SEC)
                    logger.log("Tracker task will ping", type: .trackerRequests)
                    try await regularTrackerPing()
                }
            }

            if let trackerID = dict["tracker id"] as? String {
                self.trackerID = trackerID
            }

            if let incomplete = dict["incomplete"] as? Int {
                print("Peers with incomplete file: \(incomplete)")
            } else {
                print("No incomplete key!")
            }
            if let complete = dict["complete"] as? Int {
                print("Peers with complete file: \(complete)")
            } else {
                print("No complete key!")
            }

            logger.log("Attempting to convert peers dict", type: .peerDataParsing)
            guard let peersDict = dict["peers"] as? [[String: Any]] else {
                fatalError("No peers!")
            }
            let peers = peersDict.map(PeerData.init(from:))
            self.peers = peers
            logger.log("Got peers!", type: .peerDataParsing)

            peerManagementQueue.async {
                while self.shim.socketOperationsShouldContinue {
                    guard let peer = self.shim.nextPeerForConnection() else {
                        continue
                    }
                    logger.log("Attempting to form connection to new peer", type: .outgoingSocketConnections)
                    //TODO: change queues
                    //here we should move to peerQueue, because as it stands we only connect one at a time
                    do {
                        let s = try Socket.create()
                        logger.log("Connecting to peer \(peer.peerID.hexStringEncoded()) at \(peer.ip):\(peer.port)", type: .outgoingSocketConnections)
                        try s.connect(to: peer.ip, port: peer.port)
                        logger.log("Connected to peer \(peer.peerID.hexStringEncoded()) at \(peer.ip):\(peer.port)", type: .outgoingSocketConnections)
                        try s.write(from: self.handshake)
                        logger.log("Wrote handshake to peer \(peer.peerID.hexStringEncoded()) at \(peer.ip):\(peer.port)", type: .outgoingSocketConnections)
                        var buf = Data()
                        let bytesRead = try s.read(into: &buf, bytes: 68)
                        logger.log("Read handshake from peer \(peer.peerID.hexStringEncoded()) at \(peer.ip):\(peer.port)", type: .outgoingSocketConnections)
                        //if the remote connection closes, might throw in above line, `bytesRead` might be 0, or might fail the below check
                        guard !s.remoteConnectionClosed else {
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil) //the error doesn't matter because it gets caught immediately and ignored
                        }
                        guard bytesRead > 0 else {
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil)
                        }
                        let _infoHash = buf[28..<48]
                        guard _infoHash == self.torrentFile.infoHash else {
                            logger.log("Peer \(peer.peerID.hexStringEncoded()) had infoHash \(_infoHash.hexStringEncoded()) but this download has infoHash \(self.torrentFile.infoHash.hexStringEncoded()); closing socket", type: .outgoingSocketConnections)
                            s.close() //should never happen because the peer would just close the connection
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil)
                        }
                        let _peerID = buf[48...]
                        guard peer.peerID == _peerID else {
                            logger.log("Peer \(peer.peerID.hexStringEncoded()) somehow changed to peerID \(_peerID.hexStringEncoded())", type: .outgoingSocketConnections)
                            s.close()
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil)
                        }
                        self.addPeerSocket(s)
                    } catch {
                        logger.log("Caught an error while trying to connect to peer \(peer.peerID.hexStringEncoded()) (most likely custom error); ignoring (continues to next peer)", type: .outgoingSocketConnections)
                        self.shim.failedToConnectToPeer()
                    }
                }
            }

            state = .running
            /* Here is an example response to a 'started' message


             ▿ 4 key/value pairs
               ▿ (2 elements)
                 - key: "peers"
                 ▿ value: 50 elements
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "70.58.238.62"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-bk87cdhsfk2r"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-5eumk689ftoy"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "45.2.209.90"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2930-nuvxkk87mz4j"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 16881
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "102.35.51.238"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 56920
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "194.36.25.32"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-fdbpcyr5ri6n"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-r51cwg2f1slk"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51410
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "84.13.181.75"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2840-81f2uz2wcidc"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "2.44.253.180"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "80.82.54.218"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-kc8tukcyusq3"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "62.47.233.239"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2820-h5tq16sgqfzc"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 7777
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 50000
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "159.196.40.54"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D80-âÚ\u{07}N¼\u{1B}ê÷V;"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51327
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "85.244.11.55"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D60-\u{17}r\u{05}û¦\u{18}\u{03}Çru´"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "96.241.99.27"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 16881
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2930-qidqoxlf3l2e"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D60-Ò2õ¼³¸\u{19}\u{10}e¯\0ï"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "178.162.139.101"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 10084
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "98.202.22.174"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-9q170o1frn47"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "216.26.216.103"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-4n24mgom85d1"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 54545
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "185.148.3.225"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D80-ÏÝ\u{03}ßÍÉ@ÙüJÛÉ"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 40876
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "79.142.69.160"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-2bzafsjdoy3m"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 47249
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "69.157.56.95"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2930-3tp7uv2rkwom"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 16827
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-pr94hwwqo9no"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "77.37.234.32"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 4666
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-2zfric41wncz"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "88.18.58.130"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 6971
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "51.174.215.38"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-j9ccktkzmy04"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "193.200.42.118"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "A2-1-35-0-RVøQºÚ¾\u{7F}æÕ"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 6958
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D60-9Â¢\u{12}\u{11}«§W¢\u{06}"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "181.214.206.200"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 50522
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 54829
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-y45wzoi1cq7i"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "185.65.134.162"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "83.128.53.1"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2920-ivqgd5dzijj3"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 50000
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D70-é·Â\u{17}k\u{0C}\u{11}×Y5±"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "51.15.173.30"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "51.159.4.102"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-pgctdsfd26ny"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 59928
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "45.13.105.44"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-s88awbqeeo8x"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-ujx6z2go4821"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "66.67.96.208"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-wclz9u3r2kdc"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "123.145.42.87"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "5.39.78.162"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 6890
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D60-îùeDãdï+\u{7F}"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D60-X.ÂNë¤ÿ³\u{1D}&"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 55609
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "185.157.245.99"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-u4mvfuydy91t"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "116.86.76.236"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2840-9toafhpm7xtw"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 9061
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "88.156.181.21"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D80-¢ðð%Bo^mÆd["
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "109.238.35.178"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 26890
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-okx87629qdzx"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 54555
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "24.239.251.50"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "181.214.206.149"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "TIX0289-b2e1j6e6d9e8"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 49704
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "91.121.159.144"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D80-eõíWÂ^¹¥Ê-¿"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 45002
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 6663
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D80-°Í=òq\u{1C}.i/]-"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "46.4.115.6"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-n7tp5k638a17"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "212.159.100.58"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 33413
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "84.75.162.190"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-mv8pup0ok4i9"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-qza4taj79prf"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "77.110.178.25"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-skofd7ckvxvi"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 50655
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "82.131.229.229"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "157.131.246.156"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-b4qny36yach0"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "51.15.177.153"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 53066
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-DE13F0-~bCf(uZ6Mrbv"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "138.197.143.248"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-DE205s-!9OH)Qd_!skq"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 50367
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "91.121.7.132"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-lm9zxj2zab6d"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-vhaphvqqjw2g"
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "185.44.107.109"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR2940-x6cp4ya60rqx"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 58458
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "46.246.3.209"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "port"
                       - value: 51413
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "71.174.69.152"
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-TR3000-v10ey3vewqvz"
                   ▿ 3 key/value pairs
                     ▿ (2 elements)
                       - key: "ip"
                       - value: "83.149.70.112"
                     ▿ (2 elements)
                       - key: "port"
                       - value: 47602
                     ▿ (2 elements)
                       - key: "peer id"
                       - value: "-lt0D60-2+º^þáÂØ(\nuf"
               ▿ (2 elements)
                 - key: "incomplete"
                 - value: 38
               ▿ (2 elements)
                 - key: "complete"
                 - value: 2058
               ▿ (2 elements)
                 - key: "interval"
                 - value: 1800
             */
        }
    }
    @discardableResult public func stop() -> Task<Void, Error> {
//    public func stop() {
        precondition(state == .running)
        trackerTask?.cancel()
        trackerTask = nil //probably unnecessary //could be used to mark whether we are going or not
        shouldBeListening = false
        socketOperationsShouldContinue = false
        state = .stopping

        return Task {
//        Task {
            let req = buildTrackerRequest(uploaded: self.uploaded, downloaded: self.downloaded, left: self.length - self.downloaded, event: "stopped")

            logger.log("Making stop HTTP request", type: .trackerRequests)
            let (data, response) = try await URLSession.shared.data(for: req)

            guard let response = response as? HTTPURLResponse else {
                fatalError("Stopping request had invalid response")
            }
            guard response.statusCode == 200 else {
                try? data.write(to: .init(fileURLWithPath: "/tmp/debug.dat"))
                dump(data)
                dump(response)
                fatalError("Starting request had valid response with non-OK error code")
            }

            guard let obj = try? Bencoding.object(from: data), let dict = obj as? [String: Any] else {
                try! data.write(to  : .init(fileURLWithPath: "/tmp/stop.dat"))
                fatalError("/tmp/stop.dat")
            }

            if let reason = dict["failure reason"] {
                print("Failure: \(reason)")
                return
            }

            state = .off
            /* Here is an example response to a 'stopped' message

             ▿ 4 key/value pairs
               ▿ (2 elements)
                 - key: "interval"
                 - value: 1800
               ▿ (2 elements)
                 - key: "incomplete"
                 - value: 37
               ▿ (2 elements)
                 - key: "complete"
                 - value: 2058
               ▿ (2 elements)
                 - key: "peers"
                 - value: 0 elements

             I don't think I need to take any action so long as my message worked.
             */
        }
    }
    private func downloadCompleted() {
        self.completed = true
        self.stop()
    }

    private func regularTrackerPing() async throws {
        logger.log("regularTrackerPing", type: .trackerRequests)
        let downloaded = self.downloaded
        let left = self.length - downloaded
        let req = buildTrackerRequest(uploaded: uploaded, downloaded: downloaded, left: left, event: nil)

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let response = response as? HTTPURLResponse else {
            return
        }
        guard response.statusCode == 200 else {
            return
        }

        guard let obj = try? Bencoding.object(from: data), let dict = obj as? [String: Any] else {
            try! data.write(to: .init(fileURLWithPath: "/tmp/regular.dat"))
            fatalError("/tmp/regular.dat")
        }

        if let reason = dict["failure reason"] {
            print("Failure: \(reason)")
            return
        }

        guard let interval = dict["interval"] as? Int else {
            fatalError("Missing fields")
        }
        if interval != self.interval {
            self.interval = interval
            trackerTask?.cancel()
            trackerTask = Task {
                while true {
                    try await Task.sleep(nanoseconds: UInt64(self.interval) * NSEC_PER_SEC)
                    try await regularTrackerPing()
                }
            }
        }

        if let trackerID = dict["tracker id"] as? String {
            self.trackerID = trackerID
        }

        guard let incomplete = dict["incomplete"] as? Int else {
            return
        }
        guard let complete = dict["complete"] as? Int else {
            return
        }

        guard let peersDict = dict["peers"] as? [[String: Any]] else {
            return
        }
        let peers = peersDict.map(PeerData.init(from:))
        self.peers = peers
    }

    private func buildTrackerRequest(uploaded: Int, downloaded: Int, left: Int, event: String?) -> URLRequest {
        logger.log("Building HTTP request", type: .trackerRequests)
        let _event = event == nil ? "" : "&event=\(event!)"
        let _trackerID = trackerID == nil ? "" : "&trackerid=\(trackerID!)"
        guard let port = port else {
            fatalError("Port must never be nil when making HTTP requests")
            //idk why swift tries to interpolate it as optional when i made it an implicitly unwrapped optional
        }
        var req = URLRequest(url: .init(string: torrentFile.announce.absoluteString + "?info_hash=\(urlEncodedInfoHash)&peer_id=\(peerID)&port=\(port)&uploaded=\(uploaded)&downloaded=\(downloaded)&left=\(left)\(_event)\(_trackerID)")!)
        req.httpMethod = "GET"
        return req
    }

    private nonisolated func write(_ data: Data, inPiece pieceIdx: UInt32, beginningAt byteOffset: UInt32) {
        let offset = (pieceIdx * UInt32(self.torrentFile.pieceLength)) + byteOffset
        writingQueue.async { //I feel like `.async` should be fine, because only one `async` block can run at a time, but better safe than sorry //If there is a problem, make this `.sync`
            do {
                try self.handle.seek(toOffset: UInt64(offset))
                try self.handle.write(contentsOf: data)
            } catch {
                print("unable to write!")
            }
        }
        Task {
            await self.reportDownloaded(bytes: data.count)
        }
        var haves = self.shim._getHaves()
        haves[pieceIdx] = true
        print("Piece \(pieceIdx) written; now \(haves.percentComplete, stringFormat: "%.2f")% complete")
        logger.log("Our bitfield is now \(haves.bitString)", type: .bitfields)
        self.shim._setHaves(haves)
        if haves.isComplete {
            print("Allegedly complete")
            Task {
                await self.downloadCompleted()
            }
        }
    }
    private nonisolated func read(fromPiece pieceIdx: UInt32, beginningAt byteOffset: UInt32, length: UInt32) -> Data {
        let offset = (pieceIdx * UInt32(self.torrentFile.pieceLength)) + byteOffset
        return writingQueue.sync {
            do {
                try self.handle.seek(toOffset: UInt64(offset))
                return try self.handle.read(upToCount: Int(length))!
            } catch {
                fatalError("Unable to read requested data")
            }
        }
    }

    struct PieceRequest: Equatable, Hashable {
        let idx: UInt32
        let begin: UInt32
        let length: UInt32

        func makeMessage() -> Data {
            return Data(from: UInt32(13).bigEndian) + [6] + Data(from: idx.bigEndian) + Data(from: begin.bigEndian) + Data(from: length.bigEndian)
        }
    }

    struct PieceData {
        struct WrittenSegment {
            static let MAX_LENGTH: UInt32 = 1 << 14 //2^14; 16KB
            let offset: UInt32
            let length: UInt32
            var data = Data()
            init(_ d: Data, at offset: UInt32, of length: UInt32) {
                self.data = d
                self.offset = offset
                self.length = length
            }

            func before(subsequent: WrittenSegment) -> WrittenSegment {
                precondition(self.offset + self.length == subsequent.offset)
                return .init(self.data + subsequent.data, at: self.offset, of: self.length + subsequent.length)
            }
            func after(previous: WrittenSegment) -> WrittenSegment {
                precondition(previous.offset + previous.length == self.offset)
                return .init(previous.data + self.data, at: previous.offset, of: previous.length + self.length)
            }
        }
        let idx: UInt32
        private let size: UInt32
        private let infoHash: Data
        private var writtenSegments: [WrittenSegment] = []

        init(idx: UInt32, size: UInt32, infoHash: Data) {
            self.idx = idx
            self.size = size
            self.infoHash = infoHash
        }

        mutating func receive(_ data: Data, for request: PieceRequest) {
            var segment = WrittenSegment(data, at: request.begin, of: request.length)
            if let idx = writtenSegments.firstIndex(where: { $0.offset + $0.length == segment.offset }) {
                let previous = writtenSegments.remove(at: idx)
                segment = segment.after(previous: previous)
            }
            if let idx = writtenSegments.firstIndex(where: { segment.offset + segment.length == $0.offset }) {
                let subsequent = writtenSegments.remove(at: idx)
                segment = segment.before(subsequent: subsequent)
            }
            writtenSegments.append(segment)

            writtenSegments.sort(by: { $0.offset < $1.offset })
        }

        func nextFiveRequests() -> [PieceRequest] {
//            guard let first = writtenSegments.first else {
//                //no segments
//                let fullPieces = WrittenSegment.MAX_LENGTH/size
//                if fullPieces >= 5 {
//                    var requests = [PieceRequest]()
//                    var offset = UInt32(0)
//                    for _ in 0..<5 {
//                        requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                        offset += WrittenSegment.MAX_LENGTH
//                    }
//                    return requests
//                } else { //fullPieces < 5
//                    var requests = [PieceRequest]()
//                    var offset = UInt32(0)
//                    for _ in 0..<fullPieces {
//                        requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                        offset += WrittenSegment.MAX_LENGTH
//                    }
//                    if offset < size {
//                        requests.append(.init(idx: idx, begin: offset, length: size - offset))
//                    }
//                    return requests
//                }
//            }
//            var requests = [PieceRequest]()
//            //first == first segment
//            guard first.offset == 0 else {
//                var offset = UInt32(0)
//                while offset + WrittenSegment.MAX_LENGTH <= first.offset {
//                    requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                    offset += WrittenSegment.MAX_LENGTH
//                    if requests.count == 5 {
//                        return requests
//                    }
//                }
//                if offset < first.offset {
//                    requests.append(.init(idx: idx, begin: offset, length: first.offset - offset))
//                    if requests.count == 5 {
//                        return requests
//                    }
//                }
//            }
//            var offset = first.offset + first.length
//            guard let next = writtenSegments.dropFirst().first else {
//                //only one piece
//                while offset + WrittenSegment.MAX_LENGTH <= size {
//                    requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                    offset += WrittenSegment.MAX_LENGTH
//                    if requests.count == 5 {
//                        return requests
//                    }
//                }
//                if offset < size {
//                    requests.append(.init(idx: idx, begin: offset, length: size - offset))
//                    if requests.count == 5 {
//                        return requests
//                    }
//                }
//                return requests
//            }
//            //precondition(offset < next.offset, "These two segments should have been joined!")
//            while offset + WrittenSegment.MAX_LENGTH <= next.offset {
//                requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
//                offset += WrittenSegment.MAX_LENGTH
//                if requests.count == 5 {
//                    return requests
//                }
//            }
//            if offset < next.offset {
//                requests.append(.init(idx: idx, begin: offset, length: next.offset - offset))
//                if requests.count == 5 {
//                    return requests
//                }
//            }
            var offset = UInt32(0)
            var iter = writtenSegments.makeIterator()
            var requests = [PieceRequest]()
            while true {
                guard let next = iter.next() else {
                    while offset + WrittenSegment.MAX_LENGTH <= size {
                        requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
                        offset += WrittenSegment.MAX_LENGTH
                        if requests.count == 5 {
                            return requests
                        }
                    }
                    if offset < size {
                        requests.append(.init(idx: idx, begin: offset, length: size - offset))
                        if requests.count == 5 {
                            return requests
                        }
                    }
                    return requests
                }
                if offset > next.offset {
                    fatalError()
                }
                if offset == next.offset {
                    //This better only happen for the first piece, or they should have been joined
                    precondition(offset == 0)
                    offset = next.length
                    continue
                }
                //offset < next.offset
                while offset + WrittenSegment.MAX_LENGTH <= next.offset {
                    requests.append(.init(idx: idx, begin: offset, length: WrittenSegment.MAX_LENGTH))
                    offset += WrittenSegment.MAX_LENGTH
                    if requests.count == 5 {
                        return requests
                    }
                }
                if offset < next.offset {
                    requests.append(.init(idx: idx, begin: offset, length: next.offset - offset))
                    offset = next.offset + next.length
                    if requests.count == 5 {
                        return requests
                    }
                }
            }
        }

        var isComplete: Bool {
            guard writtenSegments.count == 1 else {
                return false
            }
            let seg = writtenSegments[0]
            logger.log("Piece \(idx) is\(seg.offset == 0 && seg.length == size ? "" : " not") complete", type: .verifyingPieces)
            return seg.offset == 0 && seg.length == size
        }

        func verify() -> Data? {
            logger.log("Attempting to verify piece \(idx)", type: .verifyingPieces)
            guard isComplete else {
                return nil
            }
            let hash = Data(Insecure.SHA1.hash(data: writtenSegments[0].data))
            logger.log("Piece \(idx) is\(hash == infoHash ? "" : " not") verified", type: .verifyingPieces)
            if hash == infoHash {
                return writtenSegments[0].data
            }
            return nil
        }
    }

    /// Set up a background-executing loop for this peer socket connection that uploads and downloads pieces.
    ///
    /// This function MUST ONLY be called with a socket that is actively connected to a peer and has both sent and received a handshake. This allows this to be used for both incoming and outgoing connections, and only handle the peer wire protocol commands
    /// - Parameter socket: <#socket description#>
    private nonisolated func addPeerSocket(_ socket: Socket) {
        logger.log("In peerSocket", type: .peerSocket)
        peerQueue.async {
            do {
                var amChoking = true
                var amInterested = false
                var peerChoking = true
                var peerInterested = false
                var peerHaves = Haves.empty(ofLength: self.torrentFile.pieceCount)
                var outstandingRequests = Set<PieceRequest>()
                var canceledRequests = Set<PieceRequest>()
                var localHavesCopy = self.shim._getHaves()
                var myCurrentWorkingPiece: UInt32? = nil
                var myPieceData: PieceData? = nil

                try socket.write(from: localHavesCopy.makeMessage())
                while self.shim.socketOperationsShouldContinue {
                    //Get message
                    var data = Data()
                    let bytesRead = try socket.read(into: &data, bytes: 4)
//                    if bytesRead != 4 {
//                        if DEBUG {
//                            print("Unable to read 4 bytes to determine message size!")
//                        }
//                    }
                    let messageLength = UInt32(bigEndian: data.to(type: UInt32.self)!)
                    guard messageLength > 0 else {
                        //This message is a keep-alive; ignore it
                        continue
                    }
//                    if DEBUG {
//                        print("Got a message length of \(messageLength) bytes")
//                    }
                    let moreBytesRead = try socket.read(into: &data, bytes: Int(messageLength))
//                    if DEBUG {
//                        print("Read an additional \(moreBytesRead) bytes")
//                    }
                    switch data.first! {
                    case 0: //choke
                        logger.log("Peer choked us", type: .peerSocketDetailed)
                        peerChoking = true
                    case 1: //unchoke
                        logger.log("Peer unchoked us", type: .peerSocketDetailed)
                        peerChoking = false
                    case 2: //interested
                        logger.log("Peer is interested in us", type: .peerSocketDetailed)
                        peerInterested = true
                    case 3: //not interested
                        logger.log("Pees is not interested in us", type: .peerSocketDetailed)
                        peerInterested = false
                    case 4: //have
                        let idx = UInt32(bigEndian: data[1...].to(type: UInt32.self)!)
                        peerHaves[idx] = true
                        logger.log("Peer has piece \(idx)", type: .peerSocketDetailed)
                    case 5: //bitfield
                        let bitfield = Data(data[1...])
                        peerHaves = Haves(fromBitfield: bitfield, length: self.torrentFile.pieceCount)
                        logger.log("Peer has \(peerHaves.percentComplete, stringFormat: "%.2f")% of the file (from bitfield)", type: .peerSocketDetailed)
                        logger.log("Peer bitfield is \(peerHaves.bitString)", type: .bitfields)
                    case 6: //request
                        let idx = UInt32(bigEndian: data[1..<5].to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: data[5..<9].to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: data[9...].to(type: UInt32.self)!)
                        let req = PieceRequest(idx: idx, begin: begin, length: length)
                        logger.log("Peer requested chunk of length \(length) at offset \(begin) in piece \(idx)", type: .peerSocketDetailed)

                        if canceledRequests.contains(req) {
                            logger.log("Request had already been canceled", type: .peerSocketDetailed)
                            canceledRequests.remove(req)
                            continue
                        }

                        let block = self.read(fromPiece: idx, beginningAt: begin, length: length)
                        let output = Data(from: UInt32(9 + messageLength).bigEndian) + [7] + data[1..<9] + block
                        try socket.write(from: output)
                        logger.log("Uploaded block of length \(length) at offset \(begin) in piece \(idx) to peer", type: .peerSocketDetailed)
                        Task {
                            await self.reportUploaded(bytes: length)
                        }
                    case 7: //piece
                        let idx = UInt32(bigEndian: data[1..<5].to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: data[5..<9].to(type: UInt32.self)!)
                        let block = Data(data[9...])
                        let req = PieceRequest(idx: idx, begin: begin, length: messageLength - 9)

                        logger.log("Received response to request for \(req.length) bytes of piece \(req.idx) starting at \(req.begin)", type: .peerSocketDetailed)

                        if outstandingRequests.remove(req) != nil {
                            if req.idx == myCurrentWorkingPiece {
                                if myPieceData != nil {
                                    logger.log("Valid piece!", type: .peerSocketDetailed)
                                    myPieceData!.receive(block, for: req)
                                } else {
                                    logger.log("Cannot find piece data; ignoring piece", type: .peerSocketDetailed)
                                }
                            } else {
                                logger.log("Received block for incorrect piece; ignoring", type: .peerSocketDetailed)
                            }
                        } else {
                            logger.log("Unexpected request; ignoring", type: .peerSocketDetailed)
                        }

//                        if DEBUG {
//                            print("Got block! attempting to write...")
//                        }
//                        self.write(block, inPiece: idx, beginningAt: begin)
//                        if DEBUG {
//                            print("Wrote block in piece \(idx) at offset \(begin) to disk!")
//                        }
                    case 8: //cancel
                        let idx = UInt32(bigEndian: data[1..<5].to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: data[5..<9].to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: data[9...].to(type: UInt32.self)!)
                        let req = PieceRequest(idx: idx, begin: begin, length: length)
                        logger.log("Peer canceled request for chunk of length \(length) at offset \(begin) in piece \(idx)", type: .peerSocketDetailed)

                        canceledRequests.insert(req)
                    case 9: //port
                        let port = UInt16(bigEndian: data[1...].to(type: UInt16.self)!)
                        logger.log("Unsupported (by me) message: port \(port)", type: .peerSocketDetailed)
                    default: //invalid message
                        logger.log("Peer sent invalid message", type: .peerSocket)
                        //I'm fairly certain previous invalid message errors I was getting were due to not reading all the bytes I wanted from a previous read call. I have changed my extension to Socket to make it wait until it has the requested amount of bytes, which appears to have fixed the problem
                        socket.close()
                        throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil) //to break the loop
                    }

                    //update variables (fetch from sync queue)
                    let newLocalHavesCopy = self.shim._getHaves()
                    let newPieces = newLocalHavesCopy.newPieces(fromOld: localHavesCopy)
                    localHavesCopy = newLocalHavesCopy

                    //update variables (computations)
                    if peerChoking {
                        //From the unofficial spec:
                        //  "When a peer chokes the client, it is a notification that no requests will be answered until the client is unchoked. The client should not attempt to send requests for blocks, and it should consider all pending (unanswered) requests to be discarded by the remote peer."
                        outstandingRequests = []
                    }
                    if let idx = myCurrentWorkingPiece {
                        if localHavesCopy[idx] {
                            logger.log("Another socket finished this piece", type: .peerSocket)
                            myCurrentWorkingPiece = nil
                            myPieceData = nil
                        }
                    }
                    if true == myPieceData?.isComplete {
                        if let data = myPieceData?.verify() {
                            logger.log("Socket completed piece \(myPieceData!.idx)", type: .peerSocket)
                            self.write(data, inPiece: myPieceData!.idx, beginningAt: 0)
                            myCurrentWorkingPiece = nil
                        }
                    }
                    if myCurrentWorkingPiece == nil {
                        guard let el = zip(localHavesCopy.arr, peerHaves.arr).enumerated().filter({ idx, ziptup in
                            let (iHave, theyHave) = ziptup
                            return !iHave && theyHave
                        }).randomElement() else {
                            //This socket does not have anything we want
                            socket.close()
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil)
                            //TODO: stay connected to sockets who don't have anything
                        }
                        myCurrentWorkingPiece = UInt32(el.offset)
                        logger.log("Socket has decided to work on piece \(el.offset)", type: .peerSocket)
                        if myCurrentWorkingPiece! == self.torrentFile.pieceCount - 1 {
                            myPieceData = .init(idx: myCurrentWorkingPiece!, size: UInt32(self.length % self.torrentFile.pieceLength), infoHash: self.torrentFile.pieces[Int(myCurrentWorkingPiece!)])
                        } else {
                            myPieceData = .init(idx: myCurrentWorkingPiece!, size: UInt32(self.torrentFile.pieceLength), infoHash: self.torrentFile.pieces[Int(myCurrentWorkingPiece!)])
                        }
                    }

                    //send message
//                    guard !peerChoking else {
//                        continue
//                    }
                    var message = Data()
                    for newPiece in newPieces {//haves
                        logger.log("Informing peer that we have piece \(newPiece)", type: .peerSocketDetailed)
                        message += Data(from: UInt32(5).bigEndian) + [4] + Data(from: newPiece.bigEndian)
                    }
                    if !peerChoking {
                        if let newRequests = myPieceData?.nextFiveRequests() {
                        newRequestsLoop: for req in newRequests {
                            guard !outstandingRequests.contains(req) else {
                                continue
                            }
                                message += req.makeMessage()
                                outstandingRequests.insert(req)
                            logger.log("queueing request for \(req.length) bytes of piece \(req.idx) starting at \(req.begin)", type: .peerSocketDetailed)
                                if outstandingRequests.count == 5 {
                                    break newRequestsLoop
                                }
                            }
                        }
                    }
                    if amChoking {
                        amChoking = false
                        message += Data(from: UInt32(1).bigEndian) + [1]
                    }
                    if !amInterested {
                        if !peerHaves.newPieces(fromOld: localHavesCopy).isEmpty {
                            amInterested = true
                            message += Data(from: UInt32(1).bigEndian) + [2]
                        }
                    }

                    try socket.write(from: message)
                }
            } catch {
                self.shim.connectionToPeerClosed()
            }
        }
    }
}
extension Socket {
    @discardableResult func read(into data: inout Data, bytes: Int) throws -> Int {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bytes)
        buf.initialize(repeating: 0, count: bytes)
        var totalBytesRead = 0
        while totalBytesRead < bytes {
            let bytesRead = try self.read(into: buf + totalBytesRead, bufSize: bytes - totalBytesRead, truncate: true)
            totalBytesRead += bytesRead
        }
        data = Data(bytesNoCopy: buf, count: bytes, deallocator: .custom({ ptr, count in
            ptr.deallocate()
        }))
//        if totalBytesRead != bytes {
//            if DEBUG {
//                print("Unable to read requested quantity of bytes: wanted \(bytes) but got \(totalBytesRead)")
//            }
//        }
        return totalBytesRead
    }
}
extension Data {
    //from https://stackoverflow.com/a/38024025/8387516
    init<T>(from value: T) {
        self = Swift.withUnsafeBytes(of: value) { Data($0) }
    }

    func to<T>(type: T.Type) -> T? where T: ExpressibleByIntegerLiteral {
        var value: T = 0
        guard count >= MemoryLayout.size(ofValue: value) else { return nil }
        _ = Swift.withUnsafeMutableBytes(of: &value, { copyBytes(to: $0)} )
        return value
    }
}

extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: Double, stringFormat: String) {
        appendLiteral(String(format: stringFormat, value))
    }
}
