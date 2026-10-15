package com.example.music_player

import android.os.Build
import android.os.Bundle
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var exportResult: MethodChannel.Result? = null
    private var exportSource: File? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shiki/library_transfer")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveArchive") { result.notImplemented(); return@setMethodCallHandler }
                if (exportResult != null) { result.error("busy", "Export already active", null); return@setMethodCallHandler }
                try {
                    val source = File(call.argument<String>("path") ?: "").canonicalFile
                    require(source.isFile && source.path.startsWith(cacheDir.canonicalPath + File.separator))
                    exportSource = source
                    exportResult = result
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/zip"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "shiki-library.zip")
                    }, 7314)
                } catch (error: Exception) {
                    exportSource = null
                    exportResult = null
                    result.error("export", error.message, null)
                }
            }
    }

    @Deprecated("Android activity result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7314) return
        val result = exportResult ?: return
        val source = exportSource
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || source == null) {
            exportResult = null
            exportSource = null
            result.success(false)
            return
        }
        // Large archives stream to Android's document provider off the UI thread.
        Thread {
            try {
                contentResolver.openOutputStream(uri, "wt").use { output ->
                    requireNotNull(output)
                    source.inputStream().use { it.copyTo(output, 64 * 1024) }
                }
                runOnUiThread { exportResult = null; exportSource = null; result.success(true) }
            } catch (error: Exception) {
                runOnUiThread { exportResult = null; exportSource = null; result.error("export", error.message, null) }
            }
        }.start()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermission()
        requestBatteryOptimizationExemption()
    }

    /**
     * Android 13+ (API 33) requires runtime permission for notifications.
     * Without this, media session/foreground notification is silently blocked.
     */
    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    1001
                )
            }
        }
    }

    /**
     * Request exemption from battery optimization so the OS doesn't kill
     * our foreground service during Doze mode (screen off for extended time).
     */
    private fun requestBatteryOptimizationExemption() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                try {
                    val intent = Intent(
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Uri.parse("package:$packageName")
                    )
                    startActivity(intent)
                } catch (e: Exception) {
                    // Some OEMs block this intent; silently ignore
                }
            }
        }
    }
}
