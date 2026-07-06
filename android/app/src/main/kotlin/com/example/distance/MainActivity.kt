package com.example.distance

import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.distance/device_admin"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val dpm = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager
                val admin = ComponentName(this, DeviceAdminReceiver::class.java)

                when (call.method) {
                    "lockScreen" -> {
                        if (dpm.isAdminActive(admin)) {
                            dpm.lockNow()
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "requestAdmin" -> {
                        val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                        intent.putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, admin)
                        intent.putExtra(
                            DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                            "분실 방지를 위해 화면 잠금 권한이 필요합니다."
                        )
                        startActivity(intent)
                        result.success(true)
                    }
                    "isAdminActive" -> {
                        result.success(dpm.isAdminActive(admin))
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
