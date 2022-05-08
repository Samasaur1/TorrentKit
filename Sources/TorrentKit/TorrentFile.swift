import Foundation
import BencodingKit
import CryptoKit

struct TorrentFile {
    struct SingleFileData {
        let name: String
        let length: Int
        let md5sum: String?

        init(from dict: [String: Any]) {
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
    struct MultipleFileData {
        struct FileInfo {
            let length: Int
            let md5sum: String?
            let path: [String]

            init(from dict: [String: Any]) {
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
        let files: [TorrentFile.MultipleFileData.FileInfo]

        init(from dict: [String: Any]) {
            guard let rawName = dict["name"], let name = rawName as? String else {
                fatalError()
            }
            self.name = name
            guard let rawFiles = dict["files"], let filesArr = rawFiles as? [[String: Any]] else {
                fatalError()
            }
            self.files = filesArr.map(FileInfo.init(from:))
        }
    }
    //main->info
    let pieceLength: Int
    let pieces: [Data]
//    let `private`: Bool //Int?
    let singleFileMode: TorrentFile.SingleFileData?
    let multipleFileMode: TorrentFile.MultipleFileData?

    //main
    let announce: URL
    let announceList: [URL]?
    let creationDate: Date?
    let comment: String?
    let createdBy: String?
    let encoding: String?

    //computed
    let infoHash: Data

    enum Error: Swift.Error {
        case invalidData
    }

    init(fromContentsOf file: URL) {
        guard let data = try? Data(contentsOf: file) else {
            fatalError()
        }
        self.init(from: data)
    }

    init(from data: Data) {
        guard let obj = try? Bencoding.object(from: data) else {
            fatalError()
        }
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

        self.init(from: dict)
    }

    init(from dict: [String: Any]) {
        //main->info
        guard let rawInfo = dict["info"], let infoDict = rawInfo as? [String: Any] else {
            fatalError()
        }
        guard let rawPieceLength = infoDict["piece length"], let pieceLength = rawPieceLength as? Int else {
            fatalError()
        }
        self.pieceLength = pieceLength
        guard let rawPieces = infoDict["pieces"], let pieces = rawPieces as? Data, pieces.count.isMultiple(of: 20) else {
            fatalError()
        }
        self.pieces = pieces.chunks(ofSize: 20)
        if infoDict["length"] != nil { //single file mode
            self.singleFileMode = SingleFileData(from: infoDict)
            self.multipleFileMode = nil
        } else if infoDict["files"] != nil { //multiple file mode
            self.multipleFileMode = MultipleFileData(from: infoDict)
            self.singleFileMode = nil
        } else {
            fatalError()
        }

        //main
        guard let rawAnnounce = dict["announce"], let announceStr = rawAnnounce as? String, let announce = URL(string: announceStr) else {
            fatalError()
        }
        self.announce = announce
        self.announceList = (dict["announce-list"] as? [String])?.compactMap(URL.init(string:))
        self.creationDate = dict["creation date"] as? Date
        self.comment = dict["comment"] as? String
        self.createdBy = dict["created by"] as? String
        self.encoding = dict["encoding"] as? String

        //computed
        guard let infoDictData = try? Bencoding.data(from: infoDict) else {
            fatalError() //This should never happen since infoDict was produced by decoding
        }
        self.infoHash = Data(Insecure.SHA1.hash(data: infoDictData))
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
