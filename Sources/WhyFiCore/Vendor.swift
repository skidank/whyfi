import Foundation

public struct Vendor: Sendable, Hashable {
    public var name: String
    /// True when the BSSID is locally administered (a virtual/derived MAC) and the name was inferred.
    public var inferred: Bool

    public var label: String { inferred ? "\(name)*" : name }
}

/// IEEE MA-L (OUI) lookup.
public struct VendorDatabase: Sendable {
    private let table: [UInt32: String]

    /// `tsv`: one "XXXXXX<TAB>Name" per line.
    public init(tsv: String) {
        var t: [UInt32: String] = [:]
        for line in tsv.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let key = UInt32(line[..<tab], radix: 16) else { continue }
            t[key] = String(line[line.index(after: tab)...])
        }
        table = t
    }

    public var count: Int { table.count }

    /// APs usually derive extra BSSIDs (guest SSIDs, other radios) from their burned-in MAC by setting the
    /// locally-administered bit and twiddling the first octet. For those, try clearing that bit, then look for a
    /// globally-administered sibling that shares octets 2–3.
    public func vendor(for mac: String, siblings: [String] = []) -> Vendor? {
        guard let o = Self.octets(mac) else { return nil }
        if o[0] & 0x02 == 0 {
            return table[Self.key(o)].map { Vendor(name: $0, inferred: false) }
        }
        var cleared = o
        cleared[0] &= ~0x02
        if let n = table[Self.key(cleared)] { return Vendor(name: n, inferred: true) }
        for s in siblings {
            guard let so = Self.octets(s), so[0] & 0x02 == 0, so[1] == o[1], so[2] == o[2],
                  let n = table[Self.key(so)] else { continue }
            return Vendor(name: n, inferred: true)
        }
        return nil
    }

    private static func octets(_ mac: String) -> [UInt8]? {
        let parts = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return parts.count == 6 ? parts : nil
    }

    private static func key(_ o: [UInt8]) -> UInt32 { UInt32(o[0]) << 16 | UInt32(o[1]) << 8 | UInt32(o[2]) }
}
