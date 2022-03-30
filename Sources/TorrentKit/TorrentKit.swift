import Foundation
import BencodingKit

public struct TorrentFile {
    struct Info {
        struct SingleFileMode {
            let name: String
            let length: Int
            let md5sum: String?

            public init(from dict: [String: Any]) throws {
                guard let rawName = dict["name"], let name = rawName as? String else {
                    fatalError()
                }
                self.name = name
                guard let rawLength = dict["length"], let length = rawLength as? Int else {
                    fatalError()
                }
                self.length = length
                self.md5sum = dict["md5sum"] as? String
            }
        }
        struct MultipleFileMode {
            struct FileInfo {
                let length: Int
                let md5sum: String?
                let path: [String]

                public init(from dict: [String: Any]) throws {
                    guard let rawLength = dict["length"], let length = rawLength as? Int else {
                        fatalError()
                    }
                    self.length = length
                    self.md5sum = dict["md5sum"] as? String
                    guard let rawPath = dict["path"], let path = rawPath as? [String] else {
                        fatalError()
                    }
                    self.path = path
                }
            }
            let name: String
            let files: [TorrentFile.Info.MultipleFileMode.FileInfo]

            public init(from dict: [String: Any]) throws {
                guard let rawName = dict["name"], let name = rawName as? String else {
                    fatalError()
                }
                self.name = name
                guard let rawFiles = dict["files"], let filesArr = rawFiles as? [[String: Any]] else {
                    fatalError()
                }
                self.files = try filesArr.map(FileInfo.init(from:))
            }
        }
        let pieceLength: Int
        let pieces: [Data]
//        let `private`: Bool //Int?
        let singleFileMode: TorrentFile.Info.SingleFileMode?
        let multipleFileMode: TorrentFile.Info.MultipleFileMode?

        public init(from dict: [String: Any]) throws {
            guard let rawPieceLength = dict["piece length"], let pieceLength = rawPieceLength as? Int else {
                fatalError()
            }
            self.pieceLength = pieceLength
            guard let rawPieces = dict["pieces"], let pieces = rawPieces as? Data, pieces.count.isMultiple(of: 20) else {
                fatalError()
            }
            self.pieces = pieces.chunks(ofSize: 20)
            if dict["length"] != nil { //single file mode
                self.singleFileMode = try SingleFileMode(from: dict)
                self.multipleFileMode = nil
            } else if dict["files"] != nil { //multiple file mode
                self.multipleFileMode = try MultipleFileMode(from: dict)
                self.singleFileMode = nil
            } else {
                fatalError()
            }
        }
    }
    let info: TorrentFile.Info
    let announce: URL
    let announceList: [URL]?
    let creationDate: Date?
    let comment: String?
    let createdBy: String?
    let encoding: String?

    enum Error: Swift.Error {
        case invalidData
    }

    public init(fromContentsOf file: URL) throws {
        try self.init(from: try Data(contentsOf: file))
    }

    public init(from data: Data) throws {
        let obj = try Bencoding.object(from: data)
        guard var dict = obj as? [String: Any] else {
            fatalError()
        }

        guard var info = dict["info"] as? [String: Any] else {
            fatalError()
        }

        guard let hashStr = info["pieces"] as? String else {
            fatalError()
        }

        let hash = hashStr.hashify()
        info["pieces"] = hash
        dict["info"] = info

        try self.init(from: dict)
    }

    public init(from dict: [String: Any]) throws {
        guard let rawInfo = dict["info"], let infoDict = rawInfo as? [String: Any] else {
            fatalError()
        }
        self.info = try TorrentFile.Info(from: infoDict)
        guard let rawAnnounce = dict["announce"], let announceStr = rawAnnounce as? String, let announce = URL(string: announceStr) else {
            fatalError()
        }
        self.announce = announce
//        if let rawAnnounceList = dict["announce-list"], let announceList = raw
        self.announceList = (dict["announce-list"] as? [String])?.compactMap(URL.init(string:))
        self.creationDate = dict["creation date"] as? Date
        self.comment = dict["comment"] as? String
        self.createdBy = dict["created by"] as? String
        self.encoding = dict["encoding"] as? String
    }
}

extension Data {
    private static let hexAlphabet = Array("0123456789abcdef".unicodeScalars)
    func hexStringEncoded() -> String {
        String(reduce(into: "".unicodeScalars) { result, value in
            result.append(Self.hexAlphabet[Int(value / 0x10)])
            result.append(Self.hexAlphabet[Int(value % 0x10)])
        })
    }

    func chunks(ofSize size: Int) -> [Data] {
        return stride(from: 0, to: count, by: size).map { segmentStartIndex in
            Data(self[segmentStartIndex..<(segmentStartIndex+size)])
        }
    }
}
extension String {
    /// Converts a corrupt string, that was generated by converting a hash to a string, back to the hash (as Data)
    /// - Returns: <#description#>
    func hashify() -> Data {
        return Data(self.unicodeScalars.map { UInt8($0.value) })
    }
}
//import CryptoKit
//Insecure.SHA1.hash(data: <#T##DataProtocol#>)
