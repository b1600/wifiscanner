# Scanner

A macOS app (SwiftUI) that scans for nearby Wi-Fi networks and Bluetooth devices.

## Requirements

- macOS 14 or later
- Swift 5.9+ toolchain (Xcode or Command Line Tools)

## Build & Run

A `.app` bundle is required for Bluetooth and Location permissions, so use the build script:

```sh
./build.sh
open build/Scanner.app
```

The script builds a release binary, wraps it in `build/Scanner.app` using `Resources/Info.plist`, and ad-hoc code signs it.

## Permissions

On first launch, grant Bluetooth and Location access when prompted. macOS requires Location access to read Wi-Fi network details.

## Project Structure

- `Sources/Scanner/ScannerApp.swift` — app entry point
- `Sources/Scanner/ContentView.swift` — main UI
- `Sources/Scanner/WiFiScanner.swift` — Wi-Fi scanning (CoreWLAN)
- `Sources/Scanner/BluetoothScanner.swift` — Bluetooth scanning (CoreBluetooth)
- `Resources/Info.plist` — app bundle metadata and permission usage strings
- `build.sh` — builds and packages `Scanner.app`
