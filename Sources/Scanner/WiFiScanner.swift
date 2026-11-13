import CoreLocation
import CoreWLAN
import Foundation

struct WiFiNetwork: Identifiable, Hashable {
    let id: String
    let ssid: String
    let bssid: String
    let rssi: Int
    let noise: Int
    let channel: Int
    let band: String
    let width: String
    let security: String
    let isCurrent: Bool
}

@MainActor
final class WiFiScanner: NSObject, ObservableObject {
    @Published private(set) var networks: [WiFiNetwork] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var locationStatus: CLAuthorizationStatus
    @Published private(set) var interfaceName: String?
    @Published private(set) var lastScan: Date?

    private let locationManager = CLLocationManager()

    override init() {
        locationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        interfaceName = CWWiFiClient.shared().interface()?.interfaceName
    }

    var hasLocationAccess: Bool {
        locationStatus == .authorizedAlways || locationStatus == .authorized
    }

    func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    func scan() {
        guard !isScanning else { return }
        guard let interface = CWWiFiClient.shared().interface() else {
            errorMessage = "No Wi-Fi interface found."
            return
        }
        if interface.powerOn() == false {
            errorMessage = "Wi-Fi is turned off."
            return
        }
        isScanning = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) {
            let result: Result<[WiFiNetwork], Error>
            do {
                let currentBSSID = interface.bssid()
                let currentSSID = interface.ssid()
                let raw = try interface.scanForNetworks(withName: nil, includeHidden: true)
                result = .success(raw.map { Self.convert($0, currentSSID: currentSSID, currentBSSID: currentBSSID) })
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                self.isScanning = false
                self.lastScan = Date()
                switch result {
                case .success(let list):
                    self.networks = list.sorted { $0.rssi > $1.rssi }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    nonisolated private static func convert(_ n: CWNetwork, currentSSID: String?, currentBSSID: String?) -> WiFiNetwork {
        let ch = n.wlanChannel
        let band: String
        switch ch?.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = "—"
        }
        let width: String
        switch ch?.channelWidth {
        case .width20MHz: width = "20 MHz"
        case .width40MHz: width = "40 MHz"
        case .width80MHz: width = "80 MHz"
        case .width160MHz: width = "160 MHz"
        default: width = "—"
        }
        let ssid = n.ssid ?? ""
        let bssid = n.bssid ?? ""
        let isCurrent = (!bssid.isEmpty && bssid == currentBSSID) || (!ssid.isEmpty && ssid == currentSSID)
        return WiFiNetwork(
            id: bssid.isEmpty ? "\(ssid)|\(ch?.channelNumber ?? 0)|\(n.rssiValue)|\(UUID())" : bssid,
            ssid: ssid.isEmpty ? "(hidden)" : ssid,
            bssid: bssid.isEmpty ? "—" : bssid,
            rssi: n.rssiValue,
            noise: n.noiseMeasurement,
            channel: ch?.channelNumber ?? 0,
            band: band,
            width: width,
            security: securityDescription(n),
            isCurrent: isCurrent
        )
    }

    nonisolated private static func securityDescription(_ n: CWNetwork) -> String {
        let checks: [(CWSecurity, String)] = [
            (.wpa3Enterprise, "WPA3 Enterprise"),
            (.wpa3Personal, "WPA3 Personal"),
            (.wpa3Transition, "WPA2/WPA3"),
            (.wpa2Enterprise, "WPA2 Enterprise"),
            (.wpa2Personal, "WPA2 Personal"),
            (.wpaEnterprise, "WPA Enterprise"),
            (.wpaPersonal, "WPA Personal"),
            (.dynamicWEP, "Dynamic WEP"),
            (.WEP, "WEP"),
            (.OWE, "OWE"),
            (.oweTransition, "OWE Transition"),
            (.none, "Open"),
        ]
        for (security, label) in checks where n.supportsSecurity(security) {
            return label
        }
        return "Unknown"
    }
}

extension WiFiScanner: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.locationStatus = status
            if self.hasLocationAccess { self.scan() }
        }
    }
}
