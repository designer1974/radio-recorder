package com.designer1974.radio_recorder

import android.Manifest
import android.annotation.TargetApi
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

@TargetApi(29)
class MainActivity : FlutterActivity() {
    companion object {
        private const val REQ_PERM = 501
        private const val REQ_PROJ = 502
    }

    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private var args: Map<*, *>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rr/recorder")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> start(call.arguments as Map<*, *>, result)
                "stop" -> {
                    RecordService.stopRecording()
                    result.success(null)
                }
                "isRecording" -> result.success(RecordService.instance != null)
                else -> result.notImplemented()
            }
        }
        RecordService.onStopped = {
            runOnUiThread { channel?.invokeMethod("stopped", null) }
        }
    }

    private fun start(a: Map<*, *>, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 29) {
            result.error("OLD", "Serve Android 10 o superiore", null)
            return
        }
        if (pending != null || RecordService.instance != null) {
            result.error("BUSY", "Registrazione già in corso", null)
            return
        }
        pending = result
        args = a
        val perms = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) perms.add(Manifest.permission.POST_NOTIFICATIONS)
        val missing = perms.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), REQ_PERM)
        else afterPermissions()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_PERM || pending == null) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            afterPermissions()
        } else {
            fail("PERM", "Permesso microfono negato: serve anche per l'audio interno")
        }
    }

    private fun afterPermissions() {
        if (args?.get("internal") == true) {
            val mpm = getSystemService(MediaProjectionManager::class.java)
            @Suppress("DEPRECATION")
            startActivityForResult(mpm.createScreenCaptureIntent(), REQ_PROJ)
        } else {
            launch(null, 0)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PROJ || pending == null) return
        if (resultCode == RESULT_OK && data != null) launch(data, resultCode)
        else fail("DENIED", "Permesso di cattura audio negato")
    }

    private fun launch(data: Intent?, code: Int) {
        val a = args ?: return
        val i = Intent(this, RecordService::class.java)
            .putExtra(RecordService.EXTRA_PATH, a["path"] as String)
            .putExtra(RecordService.EXTRA_INTERNAL, a["internal"] == true)
            .putExtra(RecordService.EXTRA_NOISE, a["noise"] == true)
            .putExtra(RecordService.EXTRA_CODE, code)
        if (data != null) i.putExtra(RecordService.EXTRA_DATA, data)
        RecordService.onStarted = { err ->
            runOnUiThread {
                if (err == null) {
                    val r = pending
                    pending = null
                    args = null
                    r?.success(null)
                } else fail("START", err)
            }
        }
        startForegroundService(i)
    }

    private fun fail(code: String, msg: String) {
        val r = pending
        pending = null
        args = null
        r?.error(code, msg, null)
    }
}
