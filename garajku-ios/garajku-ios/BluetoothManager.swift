import Foundation
import CoreBluetooth

/// Monitors Bluetooth connections and notifies when the car head unit connects/disconnects.
/// On iOS, CoreBluetooth is used for BLE scanning; Classic BT (A2DP) connection events
/// are detected via ExternalAccessory framework for paired accessories, or by monitoring
/// audio route changes (head unit connects → audio routes to car speakers).
/// This implementation uses audio route monitoring as the most reliable cross-version method.

import AVFoundation

class BluetoothManager: NSObject {

    static let shared = BluetoothManager()

    var onConnected: ((_ deviceName: String) -> Void)?
    var onDisconnected: (() -> Void)?

    private var isCarConnected = false
    private var connectedDeviceName: String = ""

    private override init() {
        super.init()
        setupAudioRouteMonitoring()
    }

    func start() {
        checkCurrentAudioRoute()
    }

    // ── Audio route monitoring ─────────────────────────────────────────────
    // When the Honda City head unit connects via Bluetooth, the audio route
    // changes to include a Bluetooth output. We match the port name against
    // Config.carBtName to confirm it's the car.

    private func setupAudioRouteMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChanged(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func audioRouteChanged(_ notification: Notification) {
        checkCurrentAudioRoute()
    }

    private func checkCurrentAudioRoute() {
        let session  = AVAudioSession.sharedInstance()
        let outputs  = session.currentRoute.outputs

        // Look for a Bluetooth output matching the car name
        let btOutput = outputs.first {
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP  ||
            $0.portType == .bluetoothLE
        }

        if let bt = btOutput {
            let name = bt.portName
            let isOurCar = Config.carBtName.isEmpty ||
                           name.lowercased().contains(Config.carBtName.lowercased())
            if isOurCar && !isCarConnected {
                isCarConnected     = true
                connectedDeviceName = name
                onConnected?(name)
                // Auto-start trip
                if !TripManager.shared.isRunning {
                    TripManager.shared.start(source: "bluetooth")
                }
            }
        } else {
            if isCarConnected {
                isCarConnected     = false
                let name           = connectedDeviceName
                connectedDeviceName = ""
                onDisconnected?()
                _ = name   // used in future stop logic if needed
            }
        }
    }
}
