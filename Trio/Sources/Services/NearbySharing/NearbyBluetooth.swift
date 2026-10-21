import Foundation
import Combine
import CoreBluetooth
import CryptoKit
import Security

/// All Bluetooth callbacks and observable state are confined to the main queue.
/// A random per-family service UUID supports background discovery without broadcasting health data.
final class NearbyBluetooth: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, CBPeripheralManagerDelegate {
    let sender: Bool
    @Published private(set) var enabled = false
    @Published private(set) var status = "Off"
    @Published private(set) var packet: NearbyPacket?
    @Published private(set) var pairingCode = ""
    @Published private(set) var receivedAt: Date?
    private var pairing: NearbyPairing?
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var peer: CBPeripheral?
    private var characteristic: CBMutableCharacteristic?
    private var remoteCharacteristic: CBCharacteristic?
    private var encrypted = Data()
    private var readSnapshots: [UUID: Data] = [:]
    private var pendingNotice = false
    private var readInFlight = false
    private var readAgain = false
    private let characteristicID = CBUUID(string: "DA9BA273-7CF6-47B0-9B0F-61C72AE50E0E")
    private let keychainService = "org.trio.nearby.readonly.v1"

    init(sender: Bool) {
        self.sender = sender
        super.init()
        pairing = loadPairing()
        pairingCode = pairing?.code ?? ""
        enabled = UserDefaults.standard.bool(forKey: "nearby.readonly.enabled") && pairing != nil
        if enabled { start() }
    }

    func setEnabled(_ value: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        do {
            if value, pairing == nil {
                guard sender else { status = "Scan the pairing code on the Trio phone first"; return }
                let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try savePairing(NearbyPairing(service: UUID(), key: key))
            }
            enabled = value
            UserDefaults.standard.set(value, forKey: "nearby.readonly.enabled")
            if value { start() } else { stop(); status = "Off" }
        } catch { status = "Could not save private pairing" }
    }

    func pair(_ code: String) {
        do {
            let value = try NearbyPairing.parse(code)
            setEnabled(false)
            try savePairing(value)
            packet = nil
            receivedAt = nil
            setEnabled(true)
        } catch { status = "Invalid pairing code or unavailable keychain" }
    }

    func forget() {
        setEnabled(false)
        SecItemDelete(keychainQuery() as CFDictionary)
        pairing = nil
        pairingCode = ""
        packet = nil
        receivedAt = nil
        encrypted = Data()
        readSnapshots.removeAll()
        // Existing subscribers must not retain access to a replacement pairing.
        peripheralManager?.removeAllServices()
        characteristic = nil
        status = "Pairing removed"
    }

    func publish(_ value: NearbyPacket) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sender, enabled, let pairing else { return }
        do {
            let checked = try value.validated(now: Date().timeIntervalSince1970, previous: packet?.generatedAt)
            encrypted = try checked.sealed(key: pairing.key)
            packet = checked
            notify()
        } catch { status = "Waiting for valid local data" }
    }

    private func start() {
        guard pairing != nil else { return }
        status = "Starting Bluetooth"
        if sender {
            if peripheralManager == nil {
                peripheralManager = CBPeripheralManager(delegate: self, queue: .main, options: [
                    CBPeripheralManagerOptionRestoreIdentifierKey: "trio.nearby.sender.v1"
                ])
            } else if peripheralManager?.state == .poweredOn { advertise() }
        } else {
            if central == nil {
                central = CBCentralManager(delegate: self, queue: .main, options: [
                    CBCentralManagerOptionRestoreIdentifierKey: "loopfollow.nearby.receiver.v1"
                ])
            } else if central?.state == .poweredOn { scan() }
        }
    }

    private func stop() {
        central?.stopScan()
        if let peer { central?.cancelPeripheralConnection(peer) }
        peer = nil
        remoteCharacteristic = nil
        readInFlight = false
        readAgain = false
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        characteristic = nil
        pendingNotice = false
        readSnapshots.removeAll()
    }

    private func stateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Allow Bluetooth in iPhone Settings"
        case .unsupported: return "Bluetooth unavailable on this device"
        case .resetting: return "Bluetooth restarting"
        default: return "Waiting for Bluetooth"
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard enabled else { return }
        if peripheral.state == .poweredOn { advertise() }
        else { characteristic = nil; status = stateDescription(peripheral.state) }
    }

    private func advertise() {
        guard enabled, let pairing, let manager = peripheralManager, manager.state == .poweredOn else { return }
        if characteristic == nil {
            let value = CBMutableCharacteristic(type: characteristicID, properties: [.read, .notify], value: nil, permissions: [.readable])
            characteristic = value
            let service = CBMutableService(type: CBUUID(nsuuid: pairing.service), primary: true)
            service.characteristics = [value]
            manager.add(service)
        } else {
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: pairing.service)]])
            status = "Sharing nearby — waiting for LoopFollow"
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard enabled else { peripheral.removeAllServices(); return }
        guard error == nil, service.uuid == pairing.map({ CBUUID(nsuuid: $0.service) }) else {
            status = "Bluetooth service could not start"; return
        }
        advertise()
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if error != nil { status = "Bluetooth advertising failed — reopen Nearby Sharing" }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard enabled, request.characteristic.uuid == characteristicID, !encrypted.isEmpty else {
            peripheral.respond(to: request, withResult: .unlikelyError); return
        }
        // Freeze the entire encrypted frame for the duration of an ATT long read.
        if request.offset == 0 { readSnapshots[request.central.identifier] = encrypted }
        guard let bytes = readSnapshots[request.central.identifier], request.offset <= bytes.count else {
            peripheral.respond(to: request, withResult: .invalidOffset); return
        }
        request.value = bytes.subdata(in: request.offset..<bytes.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard enabled else { return }
        status = "Bluetooth subscriber connected"
        notify()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        readSnapshots.removeValue(forKey: central.identifier)
        status = "Sharing nearby — waiting for LoopFollow"
    }

    private func notify() {
        guard enabled, !encrypted.isEmpty, let characteristic, let manager = peripheralManager, manager.state == .poweredOn else { return }
        // A one-byte change notice fits even the minimum ATT MTU. Health data is read as one authenticated frame.
        pendingNotice = !manager.updateValue(Data([1]), for: characteristic, onSubscribedCentrals: nil)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if pendingNotice { notify() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        guard enabled, let pairing else { peripheral.removeAllServices(); peripheral.stopAdvertising(); return }
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        characteristic = services.first(where: { $0.uuid == CBUUID(nsuuid: pairing.service) })?
            .characteristics?.first(where: { $0.uuid == characteristicID }) as? CBMutableCharacteristic
        if characteristic == nil { peripheral.removeAllServices() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard enabled else { return }
        if central.state == .poweredOn { scan() }
        else { status = stateDescription(central.state); readInFlight = false }
    }

    private func scan() {
        guard enabled, let pairing, let central, central.state == .poweredOn else { return }
        if let peer, peer.state == .connected { discover(peer); return }
        status = "Searching for paired Trio phone"
        central.scanForPeripherals(withServices: [CBUUID(nsuuid: pairing.service)], options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled, peer == nil else { return }
        peer = peripheral
        peripheral.delegate = self
        central.stopScan()
        status = "Connecting to Trio"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { discover(peripheral) }

    private func discover(_ peripheral: CBPeripheral) {
        guard enabled, let pairing else { return }
        peer = peripheral
        peripheral.delegate = self
        status = "Connected — waiting for authenticated values"
        peripheral.discoverServices([CBUUID(nsuuid: pairing.service)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        peer = nil; remoteCharacteristic = nil; readInFlight = false
        if enabled { scan() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        remoteCharacteristic = nil; readInFlight = false; readAgain = false
        guard enabled else { return }
        // A pending Core Bluetooth connect survives suspension; no polling timer needed.
        peer = peripheral
        status = "Disconnected — waiting for Trio to return"
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard enabled else { restored.forEach { central.cancelPeripheralConnection($0) }; return }
        peer = restored.first
        peer?.delegate = self
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let pairing,
              let service = peripheral.services?.first(where: { $0.uuid == CBUUID(nsuuid: pairing.service) }) else {
            status = "Could not find paired sharing service"; return
        }
        peripheral.discoverCharacteristics([characteristicID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let value = service.characteristics?.first(where: { $0.uuid == characteristicID }) else {
            status = "Could not read sharing service"; return
        }
        remoteCharacteristic = value
        peripheral.setNotifyValue(true, for: value)
        read()
    }

    private func read() {
        guard enabled, let peer, let remoteCharacteristic else { return }
        if readInFlight { readAgain = true; return }
        readInFlight = true
        peer.readValue(for: remoteCharacteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil || !characteristic.isNotifying { status = "Bluetooth subscription failed" }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard enabled, characteristic.uuid == characteristicID else { return }
        if error == nil, characteristic.value == Data([1]) { read(); return }
        readInFlight = false
        defer { if readAgain { readAgain = false; read() } }
        guard error == nil, let bytes = characteristic.value, let pairing else {
            status = "Connected — waiting for local data"; return
        }
        do {
            let value = try NearbyPacket.open(bytes, key: pairing.key, now: Date().timeIntervalSince1970, previous: nil)
            if let previous = packet?.generatedAt, value.generatedAt <= previous { return }
            packet = value
            receivedAt = Date()
            status = "Receiving directly over Bluetooth"
        } catch { status = "Rejected invalid, expired or unauthenticated data" }
    }

    private func keychainQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "pairing"]
    }

    private func loadPairing() -> NearbyPairing? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(NearbyPairing.self, from: data), value.key.count == 32 else { return nil }
        return value
    }

    private func savePairing(_ value: NearbyPairing) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(keychainQuery() as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            let query = keychainQuery().merging(attributes) { _, new in new }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw NearbyError.keychain }
        } else if result != errSecSuccess { throw NearbyError.keychain }
        pairing = value
        pairingCode = value.code
    }
}
