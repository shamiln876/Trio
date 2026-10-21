import Foundation
import CryptoKit

/// Display-only wire format. No command, dosing or settings fields are accepted.
struct NearbyPacket: Codable, Equatable {
    var version = 1
    let generatedAt: Double
    let glucoseDate: Double
    let glucoseMgdl: Int
    let deltaMgdl: Int?
    let iob: Double?
    let iobDate: Double?
    let cob: Double?
    let cobDate: Double?

    func validated(now: Double, previous: Double?) throws -> NearbyPacket {
        guard version == 1, generatedAt.isFinite, glucoseDate.isFinite,
              generatedAt > 0, glucoseDate > 0,
              generatedAt <= now + 60, glucoseDate <= generatedAt + 60,
              now - generatedAt <= 15 * 60,
              previous.map({ generatedAt > $0 }) ?? true,
              (20...600).contains(glucoseMgdl),
              deltaMgdl.map({ abs(Double($0)) <= 600 }) ?? true,
              validMetric(iob, date: iobDate, lower: -1000, limit: 1000),
              validMetric(cob, date: cobDate, lower: 0, limit: 10000)
        else { throw NearbyError.invalidPacket }
        return self
    }

    private func validMetric(_ value: Double?, date: Double?, lower: Double, limit: Double) -> Bool {
        guard let value else { return date == nil }
        guard let date else { return false }
        return value.isFinite && value >= lower && value <= limit && date.isFinite && date > 0 && date <= generatedAt + 60
    }

    func sealed(key: Data) throws -> Data {
        guard key.count == 32 else { throw NearbyError.invalidPairing }
        let bytes = try JSONEncoder().encode(self)
        guard let result = try AES.GCM.seal(bytes, using: SymmetricKey(data: key)).combined,
              result.count <= 512 else { throw NearbyError.invalidPacket }
        return result
    }

    static func open(_ bytes: Data, key: Data, now: Double, previous: Double?) throws -> NearbyPacket {
        guard key.count == 32, bytes.count <= 512 else { throw NearbyError.invalidPacket }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: SymmetricKey(data: key))
        return try JSONDecoder().decode(Self.self, from: plain).validated(now: now, previous: previous)
    }
}

enum NearbyError: Error { case invalidPacket, invalidPairing, keychain }

struct NearbyPairing: Codable {
    let service: UUID
    let key: Data
    var code: String { "trio-nearby-v1:\(service.uuidString):\(key.base64EncodedString())" }

    static func parse(_ code: String) throws -> NearbyPairing {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3, parts[0] == "trio-nearby-v1",
              let service = UUID(uuidString: String(parts[1])),
              let key = Data(base64Encoded: String(parts[2])), key.count == 32
        else { throw NearbyError.invalidPairing }
        return NearbyPairing(service: service, key: key)
    }
}
