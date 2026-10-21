import Foundation
import CryptoKit

let now = 1800000000.0
let key = Data(repeating: 7, count: 32)
func rejects(_ name: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Accepted invalid case: " + name) } catch { print("PASS " + name) }
}
let packet = NearbyPacket(generatedAt: now, glucoseDate: now - 600, glucoseMgdl: 123, deltaMgdl: -5,
                          iob: -0.2, iobDate: now - 20, cob: 14, cobDate: now - 60)
let bytes = try packet.sealed(key: key)
let opened = try NearbyPacket.open(bytes, key: key, now: now, previous: nil)
precondition(opened == packet && opened.glucoseDate == now - 600)
precondition(bytes.count <= 512)
print("PASS encrypted roundtrip retains old reading time and negative IOB")
rejects("wrong pairing key") { _ = try NearbyPacket.open(bytes, key: Data(repeating: 8, count: 32), now: now, previous: nil) }
var tampered = bytes; tampered[tampered.count - 1] ^= 1
rejects("tampered ciphertext") { _ = try NearbyPacket.open(tampered, key: key, now: now, previous: nil) }
rejects("expired transfer") { _ = try NearbyPacket.open(bytes, key: key, now: now + 901, previous: nil) }
rejects("future timestamp") { _ = try packet.validated(now: now - 61, previous: nil) }
rejects("replayed transfer") { _ = try packet.validated(now: now, previous: now) }
rejects("out of order transfer") { _ = try packet.validated(now: now, previous: now + 1) }
rejects("oversized frame") { _ = try NearbyPacket.open(Data(repeating: 0, count: 513), key: key, now: now, previous: nil) }
var futureVersion = packet; futureVersion.version = 2
rejects("unsupported protocol") { _ = try futureVersion.validated(now: now, previous: nil) }
let pairing = NearbyPairing(service: UUID(), key: key)
let parsed = try NearbyPairing.parse(pairing.code)
precondition(parsed.key == key)
rejects("malformed pairing") { _ = try NearbyPairing.parse("trio-nearby-v1:bad:bad") }
let missing = NearbyPacket(generatedAt: now, glucoseDate: now, glucoseMgdl: 123, deltaMgdl: nil, iob: 1, iobDate: nil, cob: nil, cobDate: nil)
rejects("metric missing source timestamp") { _ = try missing.validated(now: now, previous: nil) }
print("ALL 12 NEARBY PROTOCOL CHECKS PASSED")
