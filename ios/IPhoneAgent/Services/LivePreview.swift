import CoreBluetooth
import Foundation

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
    private var packets: [Data] = []
    private var offset = 0
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
        subscribed.removeAll(); packets.removeAll(); latest = nil; offset = 0
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
        // Bounded queue. Drop a whole unsent event, NEVER the partially transmitted first event.
        if packets.count >= 8 { packets.remove(at: 1) }
        packets.append(wire)
        pump()
    }

    private func pump() {
        guard let manager, let output, let viewer, subscribed.contains(viewer.identifier), Date() < expires else { return }
        while let first = packets.first {
            let end = min(first.count, offset + viewer.maximumUpdateValueLength)
            guard end > offset else { return }
            let chunk = first.subdata(in: offset..<end)
            guard manager.updateValue(chunk, for: output, onSubscribedCentrals: [viewer]) else { return }
            offset = end
            if offset == first.count { packets.removeFirst(); offset = 0 }
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
                  token != nil, Date() < expires,
                  viewer == nil || viewer?.identifier == request.central.identifier else {
                peripheral.respond(to: request, withResult: .insufficientAuthorization)
                continue
            }
            viewer = request.central
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
        if viewer?.identifier == central.identifier { viewer = nil; packets.removeAll(); offset = 0 }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pump() }
}
