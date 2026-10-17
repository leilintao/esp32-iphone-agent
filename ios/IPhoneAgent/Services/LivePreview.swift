import CoreBluetooth
import Foundation

/// No stream may resume in the middle of a previous connection's JSON/JPEG event.
struct PreviewOutbox {
    private(set) var packets: [Data] = []
    private(set) var offset = 0
    mutating func reset() { packets.removeAll(); offset = 0 }
    mutating func enqueue(_ data: Data) {
        if packets.count >= 8 { packets.remove(at: 1) }
        packets.append(data)
    }
    func peek(limit: Int) -> Data? {
        guard let first = packets.first, limit > 0 else { return nil }
        return first.subdata(in: offset..<min(first.count, offset + limit))
    }
    mutating func commit(_ count: Int) {
        guard let first = packets.first else { return }
        offset += count
        if offset == first.count { packets.removeFirst(); offset = 0 }
    }
}

/// Opt-in, local Bluetooth mirror of model-call inputs. Independent of the board's video
/// characteristic: never subscribes a second video consumer or delays the agent for a viewer.
@MainActor final class LivePreview: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    static let serviceID = CBUUID(string: "23F64110-FA71-420D-A64B-85D83836F010")
    static let authID = CBUUID(string: "23F64110-FA71-420D-A64B-85D83836F011")
    static let dataID = CBUUID(string: "23F64110-FA71-420D-A64B-85D83836F012")
    private var manager: CBPeripheralManager?
    private var token: String?
    private var expires = Date.distantPast
    private var viewer: CBCentral?
    private var subscribed = Set<UUID>()
    private var output: CBMutableCharacteristic?
    private var outbox = PreviewOutbox()
    private var latest: Data?
    private var expiryTask: Task<Void, Never>?

    /// A fresh 128-bit token is supplied by the local Mac over the existing debug control link.
    func enable(_ secret: String) -> Bool {
        guard secret.count == 32, secret.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return false }
        disable()
        token = secret
        expires = Date().addingTimeInterval(3600)
        manager = CBPeripheralManager(delegate: self, queue: .main)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) } catch { return }
            self?.disable()
        }
        return true
    }

    func disable() {
        expiryTask?.cancel(); expiryTask = nil
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager?.delegate = nil
        manager = nil; token = nil; viewer = nil; output = nil
        subscribed.removeAll(); outbox.reset(); latest = nil
    }

    func publish(_ fields: [String: Any], image: Data? = nil) {
        guard token != nil, Date() < expires else { return }
        var event = fields
        event["time"] = Date().timeIntervalSince1970
        if let image { event["image"] = image.base64EncodedString() }
        guard let json = try? JSONSerialization.data(withJSONObject: event), json.count <= 2_000_000 else { return }
        let n = UInt32(json.count)
        var wire = Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        wire.append(json)
        if image != nil { latest = wire }
        enqueue(wire)
    }

    private func enqueue(_ wire: Data) {
        guard viewer != nil else { return }
        outbox.enqueue(wire)
        pump()
    }

    private func pump() {
        guard let manager, let output, let viewer, subscribed.contains(viewer.identifier), Date() < expires else { return }
        while let chunk = outbox.peek(limit: viewer.maximumUpdateValueLength) {
            guard manager.updateValue(chunk, for: output, onSubscribedCentrals: [viewer]) else { return }
            outbox.commit(chunk.count)
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn, token != nil else { return }
        let auth = CBMutableCharacteristic(type: Self.authID, properties: [.write], value: nil, permissions: [.writeable])
        let data = CBMutableCharacteristic(type: Self.dataID, properties: [.notify], value: nil, permissions: [])
        output = data
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [auth, data]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID],
                                     CBAdvertisementDataLocalNameKey: "Tianbao Preview"])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == Self.authID, request.offset == 0,
                  let value = request.value, String(data: value, encoding: .utf8) == token,
                  token != nil, Date() < expires else {
                peripheral.respond(to: request, withResult: .insufficientAuthorization)
                continue
            }
            viewer = request.central
            // Authentication starts a fresh framed stream, even if iOS retained a stale
            // central after a radio interruption and never delivered didUnsubscribe.
            outbox.reset()
            peripheral.respond(to: request, withResult: .success)
            if let latest { enqueue(latest) }
            pump()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        subscribed.insert(central.identifier)
        pump()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribed.remove(central.identifier)
        if viewer?.identifier == central.identifier { viewer = nil; outbox.reset() }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pump() }
}
