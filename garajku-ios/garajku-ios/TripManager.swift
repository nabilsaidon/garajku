import Foundation
import CoreLocation

/// Manages GPS trip recording — mirrors the Android TripService logic exactly.
/// Uses anchor-point net displacement to prevent parked GPS jitter.
class TripManager: NSObject, CLLocationManagerDelegate {

    static let shared = TripManager()

    // ── State ──────────────────────────────────────────────────────────────
    private(set) var isRunning = false
    private(set) var currentSpeed: Double = 0
    private(set) var currentDist: Double = 0   // km
    private(set) var maxSpeed: Double = 0
    private(set) var elapsedMs: Int64 = 0

    var onUpdate: ((_ speed: Double, _ dist: Double, _ elapsed: Int64, _ max: Double) -> Void)?
    var onAutoStarted: ((_ source: String) -> Void)?
    var onStopped: ((_ km: Double, _ dur: Int64, _ max: Double) -> Void)?

    // ── GPS ────────────────────────────────────────────────────────────────
    private let locationManager = CLLocationManager()
    private var tripStartDate: Date?
    private var distMetres: Double = 0
    private var maxSpeedKmh: Double = 0
    private var anchor: CLLocation?
    private var anchorTime: Date?

    // ── Motion confirm / auto-stop ─────────────────────────────────────────
    private var motionConfirmCounter: Int = 0
    private var autoStopCounter: Int = 0

    // ── Timer ──────────────────────────────────────────────────────────────
    private var broadcastTimer: Timer?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.activityType = .automotiveNavigation
    }

    // ── Public API ─────────────────────────────────────────────────────────

    func requestPermission() {
        locationManager.requestAlwaysAuthorization()
    }

    func start(source: String = "manual") {
        guard !isRunning else { return }
        isRunning       = true
        tripStartDate   = Date()
        distMetres      = 0
        maxSpeedKmh     = 0
        anchor          = nil
        anchorTime      = nil
        currentDist     = 0
        currentSpeed    = 0
        maxSpeed        = 0
        elapsedMs       = 0

        locationManager.startUpdatingLocation()
        startBroadcastTimer()

        if source == "auto" {
            onAutoStarted?("motion")
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        locationManager.stopUpdatingLocation()

        let finalKm  = distMetres / 1000.0
        let duration = Int64((Date().timeIntervalSince(tripStartDate ?? Date())) * 1000)
        onStopped?(finalKm, duration, maxSpeedKmh)

        currentSpeed = 0
    }

    // ── CLLocationManagerDelegate ──────────────────────────────────────────

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            onFix(loc)
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            // Permission granted — nothing to do here, start() will begin updates
        }
    }

    // ── GPS fix processing ─────────────────────────────────────────────────

    private func onFix(_ loc: CLLocation) {
        // Reject poor accuracy
        guard loc.horizontalAccuracy <= Config.gpsMaxAccuracyM,
              loc.horizontalAccuracy >= 0 else { return }

        // Speed
        let speedKmh = loc.speed >= 0 ? loc.speed * 3.6 : currentSpeed
        currentSpeed = max(0, speedKmh)
        if speedKmh > maxSpeedKmh && speedKmh < 300 {
            maxSpeedKmh = speedKmh
            maxSpeed    = maxSpeedKmh
        }

        // Motion auto-start / auto-stop
        checkAutoMotion(speedKmh: speedKmh)

        guard isRunning else { return }

        // Anchor-point displacement — mirrors Android exactly
        if let cur = anchor, let curTime = anchorTime {
            let net  = cur.distance(from: loc)
            let gate = max(10.0, loc.horizontalAccuracy * 0.8)
            if net >= gate {
                let span = max(1.0, loc.timestamp.timeIntervalSince(curTime))
                distMetres += min(net, span * 90.0)   // cap ~324 km/h
                anchor     = loc
                anchorTime = loc.timestamp
            }
        } else {
            anchor     = loc
            anchorTime = loc.timestamp
        }
        currentDist = distMetres / 1000.0
    }

    private func checkAutoMotion(speedKmh: Double) {
        if !isRunning {
            if speedKmh >= Config.motionStartSpeedKmh {
                motionConfirmCounter += 1
                let needed = Int(Config.motionConfirmSeconds / Config.gpsIntervalSeconds / 2)
                if motionConfirmCounter >= needed {
                    start(source: "auto")
                    motionConfirmCounter = 0
                }
            } else {
                motionConfirmCounter = 0
            }
            return
        }
        if speedKmh < Config.motionStopSpeedKmh {
            autoStopCounter += 1
            let needed = Int(Config.autoStopSeconds / Config.gpsIntervalSeconds / 2)
            if autoStopCounter >= needed {
                stop()
                autoStopCounter = 0
            }
        } else {
            autoStopCounter = 0
        }
    }

    // ── Broadcast timer ────────────────────────────────────────────────────

    private func startBroadcastTimer() {
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.elapsedMs = Int64((Date().timeIntervalSince(self.tripStartDate ?? Date())) * 1000)
            self.onUpdate?(self.currentSpeed, self.currentDist, self.elapsedMs, self.maxSpeed)
        }
    }
}
