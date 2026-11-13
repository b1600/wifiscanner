import CoreBluetooth
import Foundation
import IOBluetooth

struct BluetoothDevice: Identifiable, Hashable {
    enum Kind: String { case le = "BLE", classic = "Classic" }

    let id: String
    var name: String
    var kind: Kind
    var rssi: Int?
    var address: String
    var manufacturer: String
    var detail: String
    var connectable: Bool?
    var paired: Bool
    var connected: Bool
    var lastSeen: Date
}

@MainActor
final class BluetoothScanner: NSObject, ObservableObject {
    @Published private(set) var devices: [String: BluetoothDevice] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var stateMessage: String?

    private var central: CBCentralManager!
    private var inquiry: IOBluetoothDeviceInquiry?
    private var wantsScan = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var sortedDevices: [BluetoothDevice] {
        devices.values.sorted { ($0.rssi ?? -999, $0.name) > ($1.rssi ?? -999, $1.name) }
    }

    func start() {
        wantsScan = true
        loadPairedDevices()
        startLEScan()
        startClassicInquiry()
        isScanning = true
    }

    func stop() {
        wantsScan = false
        if central.isScanning { central.stopScan() }
        inquiry?.stop()
        inquiry = nil
        isScanning = false
    }

    func clear() {
        devices.removeAll()
        if wantsScan { loadPairedDevices() }
    }

    // MARK: - BLE

    private func startLEScan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    // MARK: - Classic

    private func startClassicInquiry() {
        guard central.state == .poweredOn, inquiry == nil else { return }
        let inq = IOBluetoothDeviceInquiry(delegate: self)
        inq?.updateNewDeviceNames = true
        inq?.inquiryLength = 10
        inquiry = inq
        inq?.start()
    }

    private func loadPairedDevices() {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        for device in paired { upsertClassic(device, rssi: nil, paired: true) }
    }

    fileprivate func upsertClassic(_ device: IOBluetoothDevice, rssi: Int?, paired: Bool) {
        let address = device.addressString ?? "unknown"
        let id = "classic-\(address)"
        let rawRSSI = Int(device.rawRSSI())
        let measured = rssi ?? ((rawRSSI != 127 && rawRSSI != 0) ? rawRSSI : nil)
        var entry = devices[id] ?? BluetoothDevice(
            id: id, name: "", kind: .classic, rssi: nil, address: address,
            manufacturer: "—", detail: "", connectable: true, paired: paired,
            connected: false, lastSeen: Date()
        )
        entry.name = device.name ?? device.nameOrAddress ?? address
        if let measured { entry.rssi = measured }
        entry.paired = entry.paired || paired || device.isPaired()
        entry.connected = device.isConnected()
        entry.detail = Self.classDescription(major: device.deviceClassMajor)
        entry.lastSeen = Date()
        devices[id] = entry
    }

    private static func classDescription(major: BluetoothDeviceClassMajor) -> String {
        switch Int(major) {
        case kBluetoothDeviceClassMajorComputer: return "Computer"
        case kBluetoothDeviceClassMajorPhone: return "Phone"
        case kBluetoothDeviceClassMajorLANAccessPoint: return "Network"
        case kBluetoothDeviceClassMajorAudio: return "Audio"
        case kBluetoothDeviceClassMajorPeripheral: return "Peripheral"
        case kBluetoothDeviceClassMajorImaging: return "Imaging"
        case kBluetoothDeviceClassMajorWearable: return "Wearable"
        case kBluetoothDeviceClassMajorToy: return "Toy"
        case kBluetoothDeviceClassMajorHealth: return "Health"
        default: return "Other"
        }
    }

    nonisolated fileprivate static func manufacturerName(from data: Data?) -> String {
        guard let data, data.count >= 2 else { return "—" }
        let companyID = UInt16(data[data.startIndex]) | (UInt16(data[data.startIndex + 1]) << 8)
        let known: [UInt16: String] = [
            0x004C: "Apple", 0x0006: "Microsoft", 0x0075: "Samsung", 0x00E0: "Google",
            0x0087: "Garmin", 0x0157: "Huami", 0x038F: "Xiaomi", 0x0059: "Nordic",
            0x000F: "Broadcom", 0x0002: "Intel", 0x001D: "Qualcomm", 0x012D: "Sony",
            0x00D2: "Dialog", 0x0499: "Ruuvi", 0x0171: "Amazon", 0x02E5: "Espressif",
            0x009E: "Bose", 0x0310: "SGL Italia", 0x0101: "Fitbit", 0x0822: "Adafruit",
        ]
        return known[companyID] ?? String(format: "0x%04X", companyID)
    }
}

extension BluetoothScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            switch state {
            case .poweredOn:
                stateMessage = nil
                if wantsScan { startLEScan(); startClassicInquiry() }
            case .poweredOff: stateMessage = "Bluetooth is turned off."
            case .unauthorized: stateMessage = "Bluetooth permission denied. Enable it in System Settings › Privacy & Security › Bluetooth."
            case .unsupported: stateMessage = "Bluetooth LE is not supported on this Mac."
            default: stateMessage = "Bluetooth is not ready."
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = "le-\(peripheral.identifier.uuidString)"
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName
        let mfg = Self.manufacturerName(from: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.description).joined(separator: ", ") ?? ""
        let rssi = RSSI.intValue
        let uuid = peripheral.identifier.uuidString

        MainActor.assumeIsolated {
            var entry = devices[id] ?? BluetoothDevice(
                id: id, name: "", kind: .le, rssi: nil, address: uuid,
                manufacturer: mfg, detail: services, connectable: connectable,
                paired: false, connected: false, lastSeen: Date()
            )
            if let name, !name.isEmpty { entry.name = name }
            if entry.name.isEmpty { entry.name = "Unknown" }
            if rssi != 127 { entry.rssi = rssi }
            if mfg != "—" { entry.manufacturer = mfg }
            if !services.isEmpty { entry.detail = services }
            if let connectable { entry.connectable = connectable }
            entry.lastSeen = Date()
            devices[id] = entry
        }
    }
}

extension BluetoothScanner: IOBluetoothDeviceInquiryDelegate {
    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let device else { return }
        MainActor.assumeIsolated { upsertClassic(device, rssi: nil, paired: false) }
    }

    nonisolated func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        guard let device else { return }
        MainActor.assumeIsolated { upsertClassic(device, rssi: nil, paired: false) }
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        MainActor.assumeIsolated {
            inquiry = nil
            // Classic inquiry runs in bursts; keep cycling while scanning.
            if wantsScan && !aborted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.wantsScan else { return }
                        self.startClassicInquiry()
                    }
                }
            }
        }
    }
}
