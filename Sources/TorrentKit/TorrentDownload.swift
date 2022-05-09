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

public var DEBUG = true
public var SOCKETEE = false

public actor TorrentDownload {
    private struct PeerData {
        let ip: String
        let port: Int32
        let peerID: Data

        init(from dict: [String: Any]) {
            if DEBUG {
                print("initting peerdata with dict \(dict)")
            }
            ip = dict["ip"] as! String
            port = Int32(dict["port"] as! Int)
            peerID = (dict["peer id"] as! String).hashify()
        }
    }
    public enum Status {
        case off, beginning, running, stopping
    }
    private class AvoidActorIsolation {
        private let shimQueue = DispatchQueue(label: "com.gauck.sam.torrentkit.shim.queue")

        var serverSocket: Socket!
        var shouldBeListening = false

        var socketOperationsShouldContinue = true

        private var _peers: [PeerData] = []
        func newPeers(_ peers: [PeerData]) {
            shimQueue.sync {
                self._peers.append(contentsOf: peers)
            }
        }
        func nextPeerForConnection() -> PeerData? {
            return shimQueue.sync {
                guard self.connectedPeers < 3 else {
                    return nil
                }
                guard !_peers.isEmpty else {
                    return nil
                }
                self.connectedPeers += 1
                return _peers.removeFirst()
            }
        }
        private var connectedPeers: Int = 0
        func failedToConnectToPeer() {
            shimQueue.sync {
                self.connectedPeers -= 1
            }
        }
//        func connectedToPeer() {
//            shimQueue.sync {
//                <#code#>
//            }
//        }
        func __connectedToPeer() {
            shimQueue.sync {
                self.connectedPeers += 1
            }
        }
        func connectionToPeerClosed() {
            self.failedToConnectToPeer()
        }
    }
    private struct /*The*/ Haves /*And The Have-Nots*/ {
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
        subscript(index: Int) -> Bool {
            get {
                arr[index]
            }
            set {
                arr[index] = newValue
            }
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
            if DEBUG {
                print("state went from \(oldValue) to \(state)")
            }
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

    public init(pathToTorrentFile url: URL) {
        //Swift complains if I say
//        self.torrentFile = torrentFile(fromContentsOf: url)
        let torrentFile = TorrentFile(fromContentsOf: url)
        precondition(torrentFile.singleFileMode != nil, "Multiple-file torrents are not yet supported")
        self.torrentFile = torrentFile
        self.length = torrentFile.length
        self.handshake = Data([19]) + "BitTorrent protocol".data(using: .ascii)! + Data(repeating: 0, count: 8) + torrentFile.infoHash + self.peerID.data(using: .ascii)!
        FileManager.default.createFile(atPath: "/tmp/\(torrentFile.singleFileMode!.name)", contents: nil)
        self.handle = try! .init(forUpdating: .init(fileURLWithPath: "/tmp/\(torrentFile.singleFileMode!.name)"))
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
                    if DEBUG {
                        print("listening socket bound to port \(_port)")
                    }
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
                    if DEBUG {
                        print("Waiting for incoming connection to socket")
                    }
                    let s = try self.shim.serverSocket.acceptClientConnection()
                    if DEBUG {
                        print("Got incoming connection to socket from \(s.remoteHostname):\(s.remotePort)")
                    }
                    let handshake_buf = UnsafeMutablePointer<CChar>.allocate(capacity: 68)
                    defer {
                        handshake_buf.deallocate()
                    }
                    var data = Data()
                    let _ = try s.read(into: &data, bytes: 68)
                    let _infoHash = data[28..<48]
                    guard _infoHash == self.torrentFile.infoHash else {
                        if DEBUG {
                            print("Incoming connection had infoHash \(_infoHash.hexStringEncoded()) but this download has infoHash \(self.torrentFile.infoHash.hexStringEncoded()); closing socket")
                        }
                        s.close()
                        return
                    }
                    let _peerID = data[48...]
                    if DEBUG {
                        print("Got peer ID \(_peerID.hexStringEncoded())")
                    }
                    try s.write(from: self.handshake)
                    self.shim.__connectedToPeer()
                    self.addPeerSocket(s)
                } catch {}
            }
        }
        Task {
            let req = buildTrackerRequest(uploaded: 0, downloaded: 0, left: self.length, event: "started")

            if DEBUG {
                print("Making initial URLRequest")
            }
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

            if DEBUG {
                print("Starting intermittent tracker task")
            }
            trackerTask = Task {
                if DEBUG {
                    print("Intermittent tracker task has begun!")
                }
                while true {
                    if DEBUG {
                        print("Tracker task will wait")
                    }
                    try await Task.sleep(nanoseconds: UInt64(self.interval) * NSEC_PER_SEC)
                    if DEBUG {
                        print("Tracker task will ping")
                    }
                    try await regularTrackerPing()
                }
            }

            if let trackerID = dict["tracker id"] as? String {
                self.trackerID = trackerID
            }

            guard let incomplete = dict["incomplete"] as? Int else {
                fatalError()
            }
            guard let complete = dict["complete"] as? Int else {
                fatalError()
            }

            if DEBUG {
                print("Attempting to convert peers dict")
            }
            guard let peersDict = dict["peers"] as? [[String: Any]] else {
                fatalError("No peers!")
            }
            let peers = peersDict.map(PeerData.init(from:))
            self.peers = peers
            if DEBUG {
                print("Got peers!")
            }

            peerManagementQueue.async {
                while self.shim.socketOperationsShouldContinue {
                    guard let peer = self.shim.nextPeerForConnection() else {
                        continue
                    }
                    if DEBUG {
                        print("Attempting to form connection to new peer")
                    }
                    //here we should move to peerQueue, because as it stands we only connect one at a time
                    do {
                        let s = try Socket.create()
                        if DEBUG {
                            print("Connecting to peer \(peer.peerID.hexStringEncoded()) at \(peer.ip):\(peer.port)")
                        }
                        try s.connect(to: peer.ip, port: peer.port)
                        if DEBUG {
                            print("Connected to peer \(peer.peerID.hexStringEncoded()) at \(peer.ip):\(peer.port)")
                        }
                        try s.write(from: self.handshake)
                        if DEBUG {
                            print("Wrote handshake to peer \(peer.peerID.hexStringEncoded()) at \(peer.ip):\(peer.port)")
                        }
                        let handshake_buf = UnsafeMutablePointer<CChar>.allocate(capacity: 68)
                        defer {
                            handshake_buf.deallocate()
                        }
                        let bytesRead = try s.read(into: handshake_buf, bufSize: 68, truncate: true)
                        if DEBUG {
                            print("Read handshake from peer \(peer.peerID.hexStringEncoded()) at \(peer.ip):\(peer.port)")
                        }
                        //if the remote connection closes, might throw in above line, `bytesRead` might be 0, or might fail the below check
                        guard !s.remoteConnectionClosed else {
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil) //the error doesn't matter because it gets caught immediately and ignored
                        }
                        guard bytesRead > 0 else {
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil)
                        }
                        let _infoHash = Data(bytesNoCopy: handshake_buf + 28, count: 20, deallocator: .none)
                        guard _infoHash == self.torrentFile.infoHash else {
                            if DEBUG {
                                print("Peer \(peer.peerID.hexStringEncoded()) had infoHash \(_infoHash.hexStringEncoded()) but this download has infoHash \(self.torrentFile.infoHash.hexStringEncoded()); closing socket")
                            }
                            s.close() //should never happen because the peer would just close the connection
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil)
                        }
                        let _peerID = Data(bytes: handshake_buf + 48, count: 20)
                        guard peer.peerID == _peerID else {
                            if DEBUG {
                                print("Peer \(peer.peerID.hexStringEncoded()) somehow changed to peerID \(_peerID.hexStringEncoded())")
                            }
                            s.close()
                            throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil)
                        }
                        self.addPeerSocket(s)
                    } catch {
                        if DEBUG {
                            print("Caught an error while trying to connect to peer \(peer.peerID.hexStringEncoded()) (most likely custom error); ignoring (continues to next peer)")
                        }
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
            let req = buildTrackerRequest(uploaded: 0, downloaded: 0, left: 0, event: "stopped")

            if DEBUG {
                print("Making stop HTTP request")
            }
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

    private func regularTrackerPing() async throws {
        if DEBUG {
            print("regularTrackerPing")
        }
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
        if DEBUG {
            print("Building HTTP request")
        }
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

    private func output(_ data: Data, atOffset offset: UInt64) {
        writingQueue.async { //I feel like `.async` should be fine, because only one `async` block can run at a time, but better safe than sorry //If there is a problem, make this `.sync`
            do {
                try self.handle.seek(toOffset: offset)
                try self.handle.write(contentsOf: data)
            } catch {
                print("unable to write!")
            }
        }
    }

    /// Set up a background-executing loop for this peer socket connection that uploads and downloads pieces.
    ///
    /// This function MUST ONLY be called with a socket that is actively connected to a peer and has both sent and received a handshake. This allows this to be used for both incoming and outgoing connections, and only handle the peer wire protocol commands
    /// - Parameter socket: <#socket description#>
    private nonisolated func addPeerSocket(_ socket: Socket) {
        if DEBUG {
            print("In peerSocket")
        }
        peerQueue.async {
            do {
                while self.shim.socketOperationsShouldContinue {
                    var data = Data()
                    let bytesRead = try socket.read(into: &data, bytes: 4)
                    let messageLength = UInt32(bigEndian: data.to(type: UInt32.self)!)
                    guard messageLength > 0 else {
                        //This message is a keep-alive; ignore it
                        continue
                    }
                    let moreBytesRead = try! socket.read(into: &data, bytes: Int(messageLength))
                    switch data.first! {
                    case 0: //choke
                        print("choke")
                    case 1: //unchoke
                        print("unchoke")
                    case 2: //interested
                        print("interested")
                    case 3: //not interested
                        print("not interested")
                    case 4: //have
                        let idx = UInt32(bigEndian: data[1...].to(type: UInt32.self)!)
                        print("have \(idx)")
                    case 5: //bitfield
                        let bitfield = Data(data[1...])
                        let haves = Haves(fromBitfield: bitfield, length: self.torrentFile.pieceCount)
                        print("bitfield \(bitfield), with pieces \(haves.arr.map { $0 ? "1" : "0"}.joined(separator: ""))")
                    case 6: //request
                        let idx = UInt32(bigEndian: data[1..<5].to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: data[5..<9].to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: data[9...].to(type: UInt32.self)!)
                        print("request \(idx) \(begin) \(length)")
                    case 7: //piece
                        let idx = UInt32(bigEndian: data[1..<5].to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: data[5..<9].to(type: UInt32.self)!)
                        let block = data[9...]
                        print("piece \(idx) \(begin) \(block)")
                    case 8: //cancel
                        let idx = UInt32(bigEndian: data[1..<5].to(type: UInt32.self)!)
                        let begin = UInt32(bigEndian: data[5..<9].to(type: UInt32.self)!)
                        let length = UInt32(bigEndian: data[9...].to(type: UInt32.self)!)
                        print("cancel \(idx) \(begin) \(length)")
                    case 9: //port
                        let port = UInt16(bigEndian: data[1...].to(type: UInt16.self)!)
                        print("port \(port)")
                    default: //invalid message
                        print("invalid message")
                        socket.close()
                        throw NSError(domain: "com.gauck.sam.torrentkit", code: 0, userInfo: nil) //to break the loop
                    }
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
        let bytesRead = try self.read(into: buf, bufSize: bytes, truncate: true)
        data = Data(bytesNoCopy: buf, count: bytes, deallocator: .custom({ ptr, count in
            ptr.deallocate()
        }))
        return bytesRead
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
//
//if let sfm = tf.singleFileMode {
//    print("sfm")
//    let length = sfm.length
//    var ur = tf.announce.absoluteString
//    ur += "?info_hash=\(infoHash)&peer_id=\(peerID)&port=6881&uploaded=0&downloaded=0&left=\(length)&event="
//    let url = URL(string: ur + "started")!
//    let url2 = URL(string: ur + "stopped")!
//    var req = URLRequest(url: url)
//    req.httpMethod = "GET"
//    var req2 = URLRequest(url: url2)
//    req2.httpMethod = "GET"
//    var waiting = true
//    let task = URLSession.shared.dataTask(with: req) { data, response, error in
//        waiting = false
//        print("r")
//        dump(data)
//        dump(response)
//        dump(error)
//        try! data!.write(to: .init(fileURLWithPath: "/tmp/data.dat"))
//        dump(try! Bencoding.object(from: data!))
//    }
//    task.resume()
//
//    while waiting {}
//    let task2 = URLSession.shared.dataTask(with: req2) { data2, response2, error2 in
//        print("r2")
//        dump(data2)
//        dump(response2)
//        dump(error2)
//        dump(try! Bencoding.object(from: data2!))
//    }
//    task2.resume()
//    while true {}
//} else if let mfm = tf.multipleFileMode {
//    print("mfm")
//    print(tf.infoHash)
//    print(tf.announce)
//    let total_length = mfm.files.map { $0.length }.reduce(0, +)
//    var u = URLComponents(url: tf.announce, resolvingAgainstBaseURL: false)!
//    let ih = tf.infoHash.hexStringEncoded()
//    //let in_ha = String(ih[..<ih.index(ih.startIndex, offsetBy: 20)])
//    let in_ha = String(bytes: tf.infoHash[..<20], encoding: .ascii)!
//    //let in_ha = String(bytes: ih, encoding: .utf8)
//    //let in_ha = ih
//    print(in_ha)
//    let peer_id = in_ha
//    u.queryItems = [
//        URLQueryItem(name: "info_hash", value: in_ha),
//        URLQueryItem(name: "peer_id", value: peer_id),
//        URLQueryItem(name: "port", value: "6881"),
//        URLQueryItem(name: "uploaded", value: "0"),
//        URLQueryItem(name: "downloaded", value: "0"),
//        URLQueryItem(name: "left", value: "\(total_length)"),
//        URLQueryItem(name: "event", value: "started")
//    ]
//    u.percentEncodedQuery = u.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
//    var u2 = URLComponents(url: tf.announce, resolvingAgainstBaseURL: false)!
//    u2.queryItems = [
//        URLQueryItem(name: "info_hash", value: in_ha),
//        URLQueryItem(name: "peer_id", value: peer_id),
//        URLQueryItem(name: "port", value: "6881"),
//        URLQueryItem(name: "uploaded", value: "0"),
//        URLQueryItem(name: "downloaded", value: "0"),
//        URLQueryItem(name: "left", value: "\(total_length)"),
//        URLQueryItem(name: "event", value: "stopped")
//    ]
//    u2.percentEncodedQuery = u.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
//    var req = URLRequest(url: u.url!)
//    req.httpMethod = "GET"
//    var req2 = URLRequest(url: u2.url!)
//    req2.httpMethod = "GET"
//    var waiting = true
//    let task = URLSession.shared.dataTask(with: req) { data, response, error in
//        waiting = false
//        print("r")
//        dump(data)
//        dump(response)
//        dump(error)
//        try! data!.write(to: .init(fileURLWithPath: "/tmp/data.dat"))
//        dump(try! Bencoding.object(from: data!))
//    }
//    task.resume()
//
//    while waiting {}
//    let task2 = URLSession.shared.dataTask(with: req2) { data2, response2, error2 in
//        print("r2")
//        dump(data2)
//        dump(response2)
//        dump(error2)
//        dump(try! Bencoding.object(from: data2!))
//    }
//    task2.resume()
//    while true {}
//} else {
//    fatalError("neither single noor multiple file")
//}
