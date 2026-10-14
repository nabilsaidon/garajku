package com.garajku

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.webkit.*
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * Single-activity host. Loads index.html from assets into a WebView
 * and wires up the native ↔ JS bridge so the trip tracker can call
 * native GPS/BT code and receive location updates.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView

    // Receives broadcasts from TripService to push data into the WebView
    private val tripReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                TripService.ACTION_UPDATE -> {
                    val speed     = intent.getDoubleExtra(TripService.EXTRA_SPEED, 0.0)
                    val dist      = intent.getDoubleExtra(TripService.EXTRA_DIST, 0.0)
                    val elapsedMs = intent.getLongExtra(TripService.EXTRA_ELAPSED, 0L)
                    val maxSpd    = intent.getDoubleExtra(TripService.EXTRA_MAX, 0.0)
                    val active    = intent.getBooleanExtra(TripService.EXTRA_ACTIVE, false)
                    runOnUiThread {
                        webView.evaluateJavascript(
                            "window.nativeTripUpdate && window.nativeTripUpdate(" +
                            "{speed:$speed,dist:$dist,elapsed:$elapsedMs,max:$maxSpd,active:$active})", null)
                    }
                }
                TripService.ACTION_AUTO_START -> {
                    val source = intent.getStringExtra(TripService.EXTRA_SOURCE) ?: "auto"
                    runOnUiThread {
                        webView.evaluateJavascript(
                            "window.nativeTripAutoStarted && window.nativeTripAutoStarted('$source')", null)
                    }
                }
                TripService.ACTION_STOPPED -> {
                    val km     = intent.getDoubleExtra(TripService.EXTRA_DIST, 0.0)
                    val dur    = intent.getLongExtra(TripService.EXTRA_ELAPSED, 0L)
                    val maxSpd = intent.getDoubleExtra(TripService.EXTRA_MAX, 0.0)
                    runOnUiThread {
                        webView.evaluateJavascript(
                            "window.nativeTripStopped && window.nativeTripStopped(" +
                            "{km:$km,dur:$dur,max:$maxSpd})", null)
                    }
                }
            }
        }
    }

    // Dynamic Bluetooth receiver (static manifest registration blocked on Android 8+)
    private val btReceiver = BluetoothReceiver()
    private var btReceiverRegistered = false

    // Thin BT event receiver that just updates the WebView badge
    private val btUiReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val device: android.bluetooth.BluetoothDevice? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    intent.getParcelableExtra(android.bluetooth.BluetoothDevice.EXTRA_DEVICE, android.bluetooth.BluetoothDevice::class.java)
                else
                    @Suppress("DEPRECATION") intent.getParcelableExtra(android.bluetooth.BluetoothDevice.EXTRA_DEVICE)
            val name = try { device?.name } catch (_: SecurityException) { null } ?: return
            val connected = intent.action == android.bluetooth.BluetoothDevice.ACTION_ACL_CONNECTED
            runOnUiThread {
                val escaped = name.replace("'", "\\'")
                webView.evaluateJavascript(
                    "window.nativeBtStatus && window.nativeBtStatus($connected,'$escaped')", null)
            }
        }
    }
    private var btUiReceiverRegistered = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        webView = findViewById(R.id.webView)
        setupWebView()
        requestRequiredPermissions()
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        // Deep link: garajku://start-trip
        if (intent?.action == Intent.ACTION_VIEW) {
            val uri = intent.data ?: return
            if (uri.scheme == "garajku" && uri.host == "start-trip") {
                val vid = uri.getQueryParameter("vehicle") ?: ""
                webView.evaluateJavascript(
                    "window.nativeDeepLink && window.nativeDeepLink('start-trip','$vid')", null)
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        webView.settings.apply {
            javaScriptEnabled           = true
            domStorageEnabled           = true
            allowFileAccessFromFileURLs = true
            databaseEnabled             = true
            mediaPlaybackRequiresUserGesture = false
            mixedContentMode            = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode                   = WebSettings.LOAD_DEFAULT
            setSupportZoom(false)
            builtInZoomControls         = false
            displayZoomControls         = false
        }

        webView.addJavascriptInterface(JsBridge(this), "GarajkuNative")

        webView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(msg: ConsoleMessage): Boolean {
                android.util.Log.d("GarajkuJS", "${msg.message()} [${msg.sourceId()}:${msg.lineNumber()}]")
                return true
            }
            override fun onGeolocationPermissionsShowPrompt(
                origin: String, callback: GeolocationPermissions.Callback) {
                callback.invoke(origin, true, false)
            }
        }

        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                injectNativeBridge()
            }
            override fun shouldOverrideUrlLoading(view: WebView, req: WebResourceRequest): Boolean {
                val uri = req.url
                return uri.scheme != "file" && uri.scheme != "javascript"
            }
        }

        webView.loadUrl(Config.APP_URL)
    }

    private fun injectNativeBridge() {
        val js = """
        (function() {
          if(window.__garajkuNativeInjected) return;
          window.__garajkuNativeInjected = true;

          const _origOpenDrive = window.openDrive;
          window.openDrive = function(vid) {
            if(_origOpenDrive) _origOpenDrive(vid);
            GarajkuNative.onDriveOpened(vid || '');
          };

          const _origStart = window.startTrip;
          window.startTrip = async function() {
            if(_origStart) await _origStart();
            GarajkuNative.startTrip(window.TRIP && window.TRIP.vid ? window.TRIP.vid : '');
          };

          const _origStop = window.stopTrip;
          window.stopTrip = async function() {
            GarajkuNative.stopTrip();
          };

          window.nativeTripUpdate = function(data) {
            if(!window.TRIP || !window.TRIP.on) return;
            window.TRIP.speed = data.speed;
            window.TRIP.dist  = data.dist;
            window.TRIP.max   = data.max;
            if(window.paintDrive) window.paintDrive();
          };

          window.nativeTripAutoStarted = function(source) {
            const vid = GarajkuNative.getActiveVehicleId();
            if(window.openDrive) window.openDrive(vid);
            setTimeout(function() {
              if(window.startTrip) window.startTrip();
              if(window.toast) window.toast(
                source === 'bluetooth' ? 'Trip started — City head unit detected'
                : 'Trip started — motion detected');
            }, 400);
          };

          window.nativeTripStopped = function(data) {
            // Native service already stopped; sync local state then show the summary
            if(window.TRIP) {
              window.TRIP.on   = false;
              window.TRIP.dist = data.km * 1000;
              window.TRIP.max  = data.max;
            }
            // Show trip summary directly (don't call stopTrip — it would early-return
            // because TRIP.on is now false, and the GPS watch is already gone)
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

          window.nativeDeepLink = function(action, vid) {
            if(action === 'start-trip') {
              if(vid && window.DB) {
                const v = window.DB.vehicles.find(function(x){return x.id===vid});
                if(v && window.openDrive) window.openDrive(v.id);
              }
              setTimeout(function(){ if(window.startTrip) window.startTrip(); }, 500);
            }
          };

          console.log('[Garajku] Native bridge injected');
        })();
        """.trimIndent()
        webView.evaluateJavascript(js, null)
    }

    override fun onResume() {
        super.onResume()

        // Register trip service receiver
        val filter = IntentFilter().apply {
            addAction(TripService.ACTION_UPDATE)
            addAction(TripService.ACTION_AUTO_START)
            addAction(TripService.ACTION_STOPPED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(tripReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(tripReceiver, filter)
        }

        // Register Bluetooth receivers dynamically (required for Android 8+)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT)
                == PackageManager.PERMISSION_GRANTED) {
            val btFilter = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
                addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            }
            if (!btReceiverRegistered) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(btReceiver, btFilter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    registerReceiver(btReceiver, btFilter)
                }
                btReceiverRegistered = true
            }
            if (!btUiReceiverRegistered) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(btUiReceiver, btFilter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    registerReceiver(btUiReceiver, btFilter)
                }
                btUiReceiverRegistered = true
            }
        }
    }

    override fun onPause() {
        super.onPause()
        try { unregisterReceiver(tripReceiver) } catch (_: Exception) {}
        if (btReceiverRegistered) {
            try { unregisterReceiver(btReceiver) } catch (_: Exception) {}
            btReceiverRegistered = false
        }
        if (btUiReceiverRegistered) {
            try { unregisterReceiver(btUiReceiver) } catch (_: Exception) {}
            btUiReceiverRegistered = false
        }
    }

    override fun onBackPressed() {
        if (webView.canGoBack()) webView.goBack() else super.onBackPressed()
    }

    // ── Permissions ───────────────────────────────────────────────────────

    private fun requestRequiredPermissions() {
    val perms = mutableListOf(
        Manifest.permission.ACCESS_FINE_LOCATION,
        Manifest.permission.ACCESS_COARSE_LOCATION,
    )
    // BLUETOOTH_CONNECT is only a runtime permission on Android 12+
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        perms += Manifest.permission.BLUETOOTH_CONNECT
        perms += Manifest.permission.BLUETOOTH_SCAN
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        perms += Manifest.permission.POST_NOTIFICATIONS
    }
    val needed = perms.filter {
        ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
    }
    if (needed.isNotEmpty()) ActivityCompat.requestPermissions(this, needed.toTypedArray(), 100)
}

    override fun onRequestPermissionsResult(req: Int, perms: Array<String>, results: IntArray) {
        super.onRequestPermissionsResult(req, perms, results)
        if (req == 100) {
            val denied = perms.zip(results.toList())
                .filter { it.second != PackageManager.PERMISSION_GRANTED }
                .map { it.first.substringAfterLast('.') }
            if (denied.isNotEmpty())
                Toast.makeText(this, "Some features need: ${denied.joinToString()}", Toast.LENGTH_LONG).show()

            // If Bluetooth permission was just granted, register the receivers now
            if (perms.contains(Manifest.permission.BLUETOOTH_CONNECT) &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT)
                    == PackageManager.PERMISSION_GRANTED) {
                val btFilter = IntentFilter().apply {
                    addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
                    addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
                }
                if (!btReceiverRegistered) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(btReceiver, btFilter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(btReceiver, btFilter)
                    }
                    btReceiverRegistered = true
                }
                if (!btUiReceiverRegistered) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(btUiReceiver, btFilter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(btUiReceiver, btFilter)
                    }
                    btUiReceiverRegistered = true
                }
            }
        }
    }
}