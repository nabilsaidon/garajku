import UIKit
import WebKit
import CoreLocation

/// Single-view controller — hosts the WKWebView and wires up the native ↔ JS bridge.
/// Mirrors Android's MainActivity exactly.
class ViewController: UIViewController {

    private var webView: WKWebView!
    private let trip = TripManager.shared
    private let bt   = BluetoothManager.shared

    // ── Lifecycle ──────────────────────────────────────────────────────────

    override func viewDidLoad() {
        super.viewDidLoad()
        setupWebView()
        setupTripCallbacks()
        setupBtCallbacks()
        trip.requestPermission()
        bt.start()
        loadApp()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bt.start()   // re-check BT route on return
    }

    // ── WebView setup ──────────────────────────────────────────────────────

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true

        // Allow localStorage from file:// URLs
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        // Register native message handlers (JS → Swift)
        let handler = NativeBridgeHandler(viewController: self)
        let names = ["startTrip", "stopTrip", "isTripActive", "getCurrentSpeed",
                     "getCurrentDist", "getElapsedMs", "getMaxSpeed",
                     "showToast", "vibrate", "nativeSave", "nativeRead",
                     "onDriveOpened", "getActiveVehicleId"]
        for name in names {
            config.userContentController.add(handler, name: name)
        }

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false

        // Dark background while loading
        webView.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
        webView.isOpaque = false

        view.addSubview(webView)
        view.backgroundColor = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    }

    private func loadApp() {
        guard let url = Bundle.main.url(forResource: Config.appFile, withExtension: "html") else {
            showToast("index.html not found in app bundle")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    // ── Trip callbacks → JS ────────────────────────────────────────────────

    private func setupTripCallbacks() {
        trip.onUpdate = { [weak self] speed, dist, elapsed, maxSpd in
            DispatchQueue.main.async {
                self?.evalJS(
                    "window.nativeTripUpdate && window.nativeTripUpdate({speed:\(speed),dist:\(dist),elapsed:\(elapsed),max:\(maxSpd),active:true})")
            }
        }
        trip.onAutoStarted = { [weak self] source in
            DispatchQueue.main.async {
                self?.evalJS(
                    "window.nativeTripAutoStarted && window.nativeTripAutoStarted('\(source)')")
            }
        }
        trip.onStopped = { [weak self] km, dur, maxSpd in
            DispatchQueue.main.async {
                self?.evalJS(
                    "window.nativeTripStopped && window.nativeTripStopped({km:\(km),dur:\(dur),max:\(maxSpd)})")
            }
        }
    }

    // ── BT callbacks → JS ─────────────────────────────────────────────────

    private func setupBtCallbacks() {
        bt.onConnected = { [weak self] name in
            DispatchQueue.main.async {
                let escaped = name.replacingOccurrences(of: "'", with: "\\'")
                self?.evalJS(
                    "window.nativeBtStatus && window.nativeBtStatus(true,'\(escaped)')")
                self?.evalJS(
                    "window.nativeTripAutoStarted && window.nativeTripAutoStarted('bluetooth')")
            }
        }
        bt.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.evalJS("window.nativeBtStatus && window.nativeBtStatus(false,'')")
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    func evalJS(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func showToast(_ message: String) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .actionSheet)
            self.present(alert, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                alert.dismiss(animated: true)
            }
        }
    }

    // Active vehicle ID — kept in sync by onDriveOpened
    var activeVehicleId: String = ""
}

// ── WKNavigationDelegate ───────────────────────────────────────────────────

extension ViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injectNativeBridge()
    }

    private func injectNativeBridge() {
        let js = """
        (function() {
          if(window.__garajkuNativeInjected) return;
          window.__garajkuNativeInjected = true;

          function native(name, args) {
            return window.webkit.messageHandlers[name].postMessage(args || null);
          }

          const _origOpenDrive = window.openDrive;
          window.openDrive = function(vid) {
            if(_origOpenDrive) _origOpenDrive(vid);
            native('onDriveOpened', vid || '');
          };

          const _origStart = window.startTrip;
          window.startTrip = async function() {
            if(_origStart) await _origStart();
            native('startTrip', window.TRIP && window.TRIP.vid ? window.TRIP.vid : '');
          };

          window.stopTrip = async function() {
            native('stopTrip', null);
          };

          window.nativeTripUpdate = function(data) {
            if(!window.TRIP || !window.TRIP.on) return;
            window.TRIP.speed = data.speed;
            window.TRIP.dist  = data.dist;
            window.TRIP.max   = data.max;
            if(window.paintDrive) window.paintDrive();
          };

          window.nativeTripAutoStarted = function(source) {
            const vid = window.__activeVehicleId || '';
            if(window.openDrive) window.openDrive(vid);
            setTimeout(function() {
              if(window.startTrip) window.startTrip();
              if(window.toast) window.toast(
                source === 'bluetooth' ? 'Trip started — City head unit detected'
                : 'Trip started — motion detected');
            }, 400);
          };

          window.nativeTripStopped = function(data) {
            if(window.TRIP) {
              window.TRIP.on   = false;
              window.TRIP.dist = data.km * 1000;
              window.TRIP.max  = data.max;
            }
            if(data.km >= 0.1 && window.TRIP && window.TRIP.vid && window.tripSummary) {
              window.tripSummary({
                km:  data.km,
                dur: data.dur,
                avg: data.dur > 0 ? data.km / (data.dur / 3600000) : 0,
                max: data.max,
                vid: window.TRIP.vid
              });
            }
          };

          console.log('[Garajku] Native bridge injected (iOS)');
        })();
        """
        evalJS(js)
    }
}

// ── JS → Native message handler ───────────────────────────────────────────

class NativeBridgeHandler: NSObject, WKScriptMessageHandler {

    weak var viewController: ViewController?

    init(viewController: ViewController) {
        self.viewController = viewController
    }

    func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard let vc = viewController else { return }
        let trip = TripManager.shared

        switch message.name {

        case "startTrip":
            let vid = message.body as? String ?? ""
            vc.activeVehicleId = vid
            trip.start(source: "manual")

        case "stopTrip":
            trip.stop()

        case "isTripActive":
            vc.evalJS("window.__nativeCb && window.__nativeCb(\(trip.isRunning))")

        case "getCurrentSpeed":
            vc.evalJS("window.__nativeCb && window.__nativeCb(\(trip.currentSpeed))")

        case "getCurrentDist":
            vc.evalJS("window.__nativeCb && window.__nativeCb(\(trip.currentDist))")

        case "getElapsedMs":
            vc.evalJS("window.__nativeCb && window.__nativeCb(\(trip.elapsedMs))")

        case "getMaxSpeed":
            vc.evalJS("window.__nativeCb && window.__nativeCb(\(trip.maxSpeed))")

        case "showToast":
            if let msg = message.body as? String { vc.showToast(msg) }

        case "vibrate":
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()

        case "nativeSave":
            if let dict = message.body as? [String: Any],
               let key  = dict["key"] as? String,
               let val  = dict["value"] as? String {
                UserDefaults.standard.set(val, forKey: key)
            }

        case "nativeRead":
            if let key = message.body as? String {
                let val = UserDefaults.standard.string(forKey: key) ?? "null"
                let escaped = val.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "'", with: "\\'")
                vc.evalJS("window.__nativeCb && window.__nativeCb('\(escaped)')")
            }

        case "onDriveOpened":
            if let vid = message.body as? String { vc.activeVehicleId = vid }

        case "getActiveVehicleId":
            let vid = vc.activeVehicleId
            vc.evalJS("window.__nativeCb && window.__nativeCb('\(vid)')")

        default:
            break
        }
    }
}
