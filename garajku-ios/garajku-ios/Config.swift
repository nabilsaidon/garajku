import Foundation

/// All tuneable settings in one place.
/// Edit this file — nowhere else needs changing.
enum Config {

    // ── Bluetooth auto-start (City head unit) ────────────────────────────
    // Exact name of your car's Bluetooth device as it appears in
    // iPhone Settings → Bluetooth (paired devices list).
    // Leave blank to disable Bluetooth auto-start.
    static let carBtName = "Cxzconverter-3E6E"   // ← change to your head unit name

    // ── Motion auto-start (SR GT 200) ───────────────────────────────────
    // Speed threshold in km/h. Trip starts when GPS reports this speed
    // sustained for motionConfirmSeconds continuously.
    static let motionStartSpeedKmh: Double = 20.0
    static let motionConfirmSeconds: Double = 8.0

    // Trip ends when speed drops below this for autoStopSeconds.
    static let motionStopSpeedKmh: Double = 5.0
    static let autoStopSeconds: Double = 120.0   // 2 minutes stationary

    // ── GPS ──────────────────────────────────────────────────────────────
    static let gpsIntervalSeconds: Double = 2.0
    static let gpsMaxAccuracyM: Double = 50.0

    // ── Storage key (must match the web app's localStorage key) ──────────
    static let storageKey = "servis:db:v1"

    // ── App HTML file ────────────────────────────────────────────────────
    static let appFile = "index"   // loads index.html from app bundle
}
