import Foundation

enum NearbySender {
    static let shared = NearbyBluetooth(sender: true)
}
