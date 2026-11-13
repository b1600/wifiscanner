import SwiftUI

struct ContentView: View {
    enum Tab: Hashable { case wifi, bluetooth }

    @StateObject private var wifi = WiFiScanner()
    @StateObject private var bluetooth = BluetoothScanner()
    @State private var tab: Tab = .wifi

    var body: some View {
        TabView(selection: $tab) {
            WiFiView(scanner: wifi)
                .tabItem { Label("Wi-Fi (\(wifi.networks.count))", systemImage: "wifi") }
                .tag(Tab.wifi)
            BluetoothView(scanner: bluetooth)
                .tabItem { Label("Bluetooth (\(bluetooth.devices.count))", systemImage: "dot.radiowaves.left.and.right") }
                .tag(Tab.bluetooth)
        }
        .padding()
        .onAppear {
            if !wifi.hasLocationAccess { wifi.requestLocationAccess() }
            wifi.scan()
            bluetooth.start()
        }
    }
}

// MARK: - Wi-Fi

struct WiFiView: View {
    @ObservedObject var scanner: WiFiScanner
    @State private var autoRefresh = true
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\WiFiNetwork.rssi, order: .reverse)]

    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var rows: [WiFiNetwork] {
        scanner.networks
            .filter { search.isEmpty || $0.ssid.localizedCaseInsensitiveContains(search) || $0.bssid.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    scanner.scan()
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isScanning)
                Toggle("Auto-refresh (10s)", isOn: $autoRefresh)
                if scanner.isScanning { ProgressView().controlSize(.small) }
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }

            if !scanner.hasLocationAccess {
                Banner(
                    text: "Network names are hidden until Location access is granted (a macOS requirement for Wi-Fi scanning).",
                    actionTitle: "Open Settings"
                ) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
            }
            if let error = scanner.errorMessage { Banner(text: error) }

            Table(rows, sortOrder: $sortOrder) {
                TableColumn("SSID", value: \.ssid) { n in
                    HStack(spacing: 4) {
                        if n.isCurrent { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        Text(n.ssid).fontWeight(n.isCurrent ? .semibold : .regular)
                    }
                }
                TableColumn("Signal", value: \.rssi) { n in SignalView(rssi: n.rssi) }
                    .width(110)
                TableColumn("Channel", value: \.channel) { n in Text("\(n.channel)") }
                    .width(60)
                TableColumn("Band", value: \.band).width(65)
                TableColumn("Width", value: \.width).width(65)
                TableColumn("Security", value: \.security)
                TableColumn("BSSID", value: \.bssid) { n in Text(n.bssid).font(.system(.body, design: .monospaced)) }
                TableColumn("Noise", value: \.noise) { n in Text("\(n.noise) dBm") }
                    .width(70)
            }

            HStack {
                Text("\(rows.count) networks")
                Spacer()
                if let last = scanner.lastScan { Text("Last scan \(last.formatted(date: .omitted, time: .standard))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        .onReceive(timer) { _ in if autoRefresh { scanner.scan() } }
    }
}

// MARK: - Bluetooth

struct BluetoothView: View {
    @ObservedObject var scanner: BluetoothScanner
    @State private var search = ""
    @State private var hideUnnamed = false
    @State private var sortOrder = [KeyPathComparator(\BluetoothDevice.sortRSSI, order: .reverse)]

    private var rows: [BluetoothDevice] {
        scanner.devices.values
            .filter { !hideUnnamed || $0.name != "Unknown" }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.manufacturer.localizedCaseInsensitiveContains(search) || $0.address.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    scanner.isScanning ? scanner.stop() : scanner.start()
                } label: {
                    Label(scanner.isScanning ? "Stop" : "Start", systemImage: scanner.isScanning ? "stop.fill" : "play.fill")
                }
                Button("Clear") { scanner.clear() }
                Toggle("Hide unnamed", isOn: $hideUnnamed)
                if scanner.isScanning { ProgressView().controlSize(.small) }
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }

            if let message = scanner.stateMessage { Banner(text: message) }

            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { d in
                    HStack(spacing: 4) {
                        if d.connected { Image(systemName: "link").foregroundStyle(.green) }
                        Text(d.name).foregroundStyle(d.name == "Unknown" ? .secondary : .primary)
                    }
                }
                TableColumn("Signal", value: \.sortRSSI) { d in
                    if let rssi = d.rssi { SignalView(rssi: rssi) } else { Text("—").foregroundStyle(.secondary) }
                }
                .width(110)
                TableColumn("Type", value: \.kind.rawValue).width(60)
                TableColumn("Manufacturer", value: \.manufacturer).width(100)
                TableColumn("Status", value: \.status).width(110)
                TableColumn("Details", value: \.detail)
                TableColumn("Identifier", value: \.address) { d in
                    Text(d.address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                TableColumn("Last seen", value: \.lastSeen) { d in
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(Self.ago(d.lastSeen, now: ctx.date))
                    }
                }
                .width(70)
            }

            Text("\(rows.count) devices · BLE identifiers are per-Mac UUIDs; macOS does not expose BLE MAC addresses.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }
}

extension BluetoothDevice {
    var sortRSSI: Int { rssi ?? -999 }
    var status: String {
        if connected { return "Connected" }
        if paired { return "Paired" }
        switch connectable {
        case true?: return "Connectable"
        case false?: return "Beacon"
        case nil: return "—"
        }
    }
}

// MARK: - Shared components

struct SignalView: View {
    let rssi: Int

    private var bars: Int {
        switch rssi {
        case (-55)...: return 4
        case (-67)...: return 3
        case (-78)...: return 2
        case (-90)...: return 1
        default: return 0
        }
    }

    private var color: Color {
        switch bars {
        case 4, 3: return .green
        case 2: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < bars ? color : Color.secondary.opacity(0.25))
                        .frame(width: 4, height: CGFloat(4 + i * 3))
                }
            }
            Text("\(rssi) dBm").monospacedDigit()
        }
    }
}

struct Banner: View {
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text)
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .font(.callout)
        .padding(8)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
