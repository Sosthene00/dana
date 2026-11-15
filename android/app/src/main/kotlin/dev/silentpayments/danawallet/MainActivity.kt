package dev.silentpayments.danawallet

import android.app.ActivityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // §6.3.2 device-class probe: the export flow asks whether this is a
    // low-RAM (Go-class) device to pick the reduced KDF profile visibly.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.silentpayments.danawallet/device"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isLowRamDevice" -> {
                    val activityManager =
                        getSystemService(ACTIVITY_SERVICE) as ActivityManager
                    result.success(activityManager.isLowRamDevice)
                }
                else -> result.notImplemented()
            }
        }
    }
}
