import Foundation

/// Binary-plist encoding for XPC history replies. `Data` needs no
/// `NSXPCInterface.setClasses` allow-listing (unlike a custom `NSSecureCoding`
/// type), matching the reasoning behind the plain-dictionary `[String: Any]`
/// replies used elsewhere in this protocol.
nonisolated enum HistoryCoding {
    private static let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    private static let decoder = PropertyListDecoder()

    /// Encoding failures here would mean a model stopped being `Codable`
    /// correctly, not a runtime/data condition — fall back to an empty
    /// payload rather than crashing the daemon.
    static func encode(_ value: some Encodable) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data) -> [T] {
        (try? decoder.decode([T].self, from: data)) ?? []
    }
}
