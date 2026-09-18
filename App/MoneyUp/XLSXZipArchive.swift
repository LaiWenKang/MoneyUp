import Compression
import Foundation

struct XLSXZipArchive {
    private struct Entry {
        let offset: Int
        let compressed: Int
        let expanded: Int
        let method: Int
        let checksum: UInt32
    }
    private let data: Data
    private var entries: [String: Entry] = [:]
    var names: [String] { Array(entries.keys) }

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw CSVImportViewError.unsupportedDocument }
        let lower = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: {
            data.uint32($0) == 0x06054b50 && $0 + 22 + data.uint16($0 + 20) == data.count
        }), data.uint16(end + 4) == 0, data.uint16(end + 6) == 0,
              data.uint16(end + 8) == data.uint16(end + 10), data.uint16(end + 10) <= 512 else {
            throw CSVImportViewError.unsupportedDocument
        }
        var offset = Int(data.uint32(end + 16))
        let centralEnd = offset + Int(data.uint32(end + 12))
        guard centralEnd == end else { throw CSVImportViewError.unsupportedDocument }
        var totalExpanded = 0
        for _ in 0..<data.uint16(end + 10) {
            try Task.checkCancellation()
            guard offset + 46 <= end, data.uint32(offset) == 0x02014b50,
                  data.uint16(offset + 8) & 1 == 0, data.uint16(offset + 34) == 0 else {
                throw CSVImportViewError.unsupportedDocument
            }
            let nameLength = data.uint16(offset + 28)
            let next = offset + 46 + nameLength + data.uint16(offset + 30) + data.uint16(offset + 32)
            guard next <= end, let name = String(data: data.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8),
                  !name.hasPrefix("/"), !name.components(separatedBy: "/").contains(".."), entries[name] == nil else {
                throw CSVImportViewError.unsupportedDocument
            }
            let entry = Entry(offset: Int(data.uint32(offset + 42)), compressed: Int(data.uint32(offset + 20)),
                              expanded: Int(data.uint32(offset + 24)), method: data.uint16(offset + 10),
                              checksum: data.uint32(offset + 16))
            totalExpanded += entry.expanded
            guard totalExpanded <= 30_000_000, entry.expanded <= 20_000_000 else { throw CSVImportViewError.documentTooLarge }
            entries[name] = entry
            offset = next
        }
        guard offset == centralEnd, entries["xl/workbook.xml"] != nil else { throw CSVImportViewError.unsupportedDocument }
    }

    func file(_ name: String) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        let offset = entry.offset
        guard offset >= 0, offset + 30 <= data.count, data.uint32(offset) == 0x04034b50,
              data.uint16(offset + 6) & 1 == 0, data.uint16(offset + 8) == entry.method else {
            throw CSVImportViewError.unsupportedDocument
        }
        let start = offset + 30 + data.uint16(offset + 26) + data.uint16(offset + 28)
        guard start <= data.count, entry.compressed <= data.count - start,
              let localName = String(data: data.subdata(in: offset + 30..<offset + 30 + data.uint16(offset + 26)), encoding: .utf8),
              localName == name else { throw CSVImportViewError.unsupportedDocument }
        let bytes = data.subdata(in: start..<start + entry.compressed)
        let expanded: Data
        if entry.method == 0 {
            guard bytes.count == entry.expanded else { throw CSVImportViewError.unsupportedDocument }
            expanded = bytes
        } else if entry.method == 8, entry.expanded > 0, !bytes.isEmpty {
            var output = Data(count: entry.expanded + 1)
            let capacity = output.count
            let count = output.withUnsafeMutableBytes { destination in
                bytes.withUnsafeBytes { source in
                    guard let outputAddress = destination.bindMemory(to: UInt8.self).baseAddress,
                          let inputAddress = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(outputAddress, capacity, inputAddress, bytes.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard count == entry.expanded else { throw CSVImportViewError.unsupportedDocument }
            expanded = output.prefix(count)
        } else { throw CSVImportViewError.unsupportedDocument }
        guard Self.crc32(expanded) == entry.checksum else { throw CSVImportViewError.unsupportedDocument }
        return expanded
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var checksum = UInt32(value)
        for _ in 0..<8 { checksum = checksum & 1 == 1 ? 0xedb88320 ^ (checksum >> 1) : checksum >> 1 }
        return checksum
    }

    private static func crc32(_ bytes: Data) -> UInt32 {
        var checksum: UInt32 = 0xffffffff
        for byte in bytes { checksum = crcTable[Int((checksum ^ UInt32(byte)) & 0xff)] ^ (checksum >> 8) }
        return ~checksum
    }
}

private extension Data {
    func uint16(_ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return Int(self[offset]) | Int(self[offset + 1]) << 8
    }

    func uint32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
