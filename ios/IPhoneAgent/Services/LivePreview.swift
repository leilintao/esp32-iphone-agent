import CoreBluetooth
import Foundation

enum PreviewAuthorization {
    static func matches(_ value: Data, token: String?) -> Bool {
        guard let token, token.count == 32 else { return false }
        // The binary form fits even a default 20-byte ATT write payload.
        if value.count == 16 {
            return value.map { String(format: "%02x", $0) }.joined() == token.lowercased()
        }
        return String(data: value, encoding: .utf8) == token
    }
}

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
    private var serviceReady = false
    private var addingService = false
    private var outbox = PreviewOutbox()
    private var latest: Data?
    private var expiryTask: Task<Void, Never>?

    /// A fresh 128-bit token is supplied by the local Mac over the existing debug control link.
    func enable(_ secret: String) -> Bool {
        guard secret.count == 32, secret.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return false }
        // A token change must not stop/restart asynchronous advertising either.
        // Revoke the old session while leaving the transport intact.
        resetAuthorization()
        token = secret
        expires = Date().addingTimeInterval(3600)
        // Keep one peripheral manager and a stable GATT database across authorizations.
        // Rotating a token must not remove services underneath a reconnecting Mac.
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: .main)
        } else if let manager, manager.state == .poweredOn {
            prepareService(manager)
        }
        DebugLog.write("preview: authorization renewed; " + status)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000) } catch { return }
            self?.disable()
        }
        return true
    }

    func disable() {
        resetAuthorization()
        manager?.stopAdvertising()
    }

    private func resetAuthorization() {
        expiryTask?.cancel(); expiryTask = nil
        token = nil; viewer = nil
        // Token revocation does not cancel the OS's existing CCCD subscriptions.
        // Keep that transport state; no bytes can leave without a new authenticated viewer.
        outbox.reset(); latest = nil
    }

    var status: String {
        "radio=\(manager?.state.rawValue ?? -1) service=\(serviceReady) advertising=\(manager?.isAdvertising ?? false) subscribers=\(subscribed.count) authenticated=\(viewer != nil)"
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
        DebugLog.write("preview: radio state \(peripheral.state.rawValue)")
        guard peripheral.state == .poweredOn else {
            output = nil; serviceReady = false; addingService = false
            viewer = nil; subscribed.removeAll(); outbox.reset()
            return
        }
        guard token != nil else { return }
        prepareService(peripheral)
    }

    private func prepareService(_ peripheral: CBPeripheralManager) {
        guard token != nil, Date() < expires else { return }
        if serviceReady { advertise(peripheral); return }
        guard !addingService else { return }
        addingService = true
        let auth = CBMutableCharacteristic(type: Self.authID, properties: [.write], value: nil, permissions: [.writeable])
        let data = CBMutableCharacteristic(type: Self.dataID, properties: [.notify], value: nil, permissions: [])
        output = data
        let service = CBMutableService(type: Self.serviceID, primary: true)
        service.characteristics = [auth, data]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        addingService = false
        if let error {
            output = nil; serviceReady = false
            DebugLog.write("preview: service registration failed: \(error.localizedDescription)")
            return
        }
        serviceReady = true
        DebugLog.write("preview: screenshot service registered")
        advertise(peripheral)
    }

    private func advertise(_ peripheral: CBPeripheralManager) {
        guard token != nil, Date() < expires, !peripheral.isAdvertising else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID],
                                     CBAdvertisementDataLocalNameKey: "Tianbao Preview"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        DebugLog.write("preview: advertising " + (error.map { "failed: \($0.localizedDescription)" } ?? "started"))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let request = requests.first else { return }
        // CoreBluetooth requires exactly one response for the entire atomic batch.
        // This protocol accepts one complete token write, never partial authorization.
        guard requests.count == 1, request.characteristic.uuid == Self.authID, request.offset == 0,
              let value = request.value, PreviewAuthorization.matches(value, token: token), Date() < expires else {
            peripheral.respond(to: request, withResult: .insufficientAuthorization)
            DebugLog.write("preview: rejected invalid or expired authorization")
            return
        }
        viewer = request.central
        outbox.reset()
        peripheral.respond(to: request, withResult: .success)
        DebugLog.write("preview: Mac authenticated")
        if let latest { enqueue(latest) }
        publish(["kind": "state", "state": "截图预览授权成功，等待真实画面"])
        pump()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        // The same Mac may reconnect with its previous central UUID. Never pump the
        // old stream on subscribe before its new receiver has authenticated.
        if viewer?.identifier == central.identifier { viewer = nil; outbox.reset() }
        subscribed.insert(central.identifier)
        DebugLog.write("preview: Mac subscribed; packet limit \(central.maximumUpdateValueLength)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribed.remove(central.identifier)
        DebugLog.write("preview: Mac unsubscribed")
        if viewer?.identifier == central.identifier { viewer = nil; outbox.reset() }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pump() }
}
