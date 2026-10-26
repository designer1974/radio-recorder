package com.designer1974.radio_recorder

import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.NoiseSuppressor
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs

/**
 * Servizio in primo piano che registra l'audio (interno o microfono)
 * e lo salva in WAV PCM 16 bit, 48 kHz.
 */
@TargetApi(29)
class RecordService : Service() {
    companion object {
        const val EXTRA_PATH = "path"
        const val EXTRA_INTERNAL = "internal"
        const val EXTRA_NOISE = "noise"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        private const val RATE = 48000
        private const val TAG = "RecordService"

        @Volatile var instance: RecordService? = null
        /** Livello attuale 0..1 (picco dell'ultimo blocco letto). */
        @Volatile var level = 0f
        var onStarted: ((String?) -> Unit)? = null
        var onStopped: (() -> Unit)? = null

        fun stopRecording() {
            instance?.finish()
        }
    }

    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var suppressor: NoiseSuppressor? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    private var finished = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        instance = this
        finished = false
        val internal = intent.getBooleanExtra(EXTRA_INTERNAL, true)
        try {
            startInForeground(internal)
            begin(intent, internal)
            onStarted?.invoke(null)
        } catch (e: Exception) {
            Log.e(TAG, "Errore avvio", e)
            cleanup()
            onStarted?.invoke(e.message ?: "Errore sconosciuto")
        }
        onStarted = null
        return START_NOT_STICKY
    }

    private fun startInForeground(internal: Boolean) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel("rec", "Registrazione", NotificationManager.IMPORTANCE_LOW)
        )
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val n = Notification.Builder(this, "rec")
            .setContentTitle("Registrazione in corso")
            .setContentText(if (internal) "Audio interno" else "Microfono")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()
        when {
            Build.VERSION.SDK_INT >= 30 -> {
                val type = if (internal)
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION or
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                else ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                startForeground(1, n, type)
            }
            internal -> startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            else -> startForeground(1, n)
        }
    }

    private fun begin(intent: Intent, internal: Boolean) {
        val path = intent.getStringExtra(EXTRA_PATH) ?: throw IllegalStateException("Percorso mancante")
        val noiseOn = intent.getBooleanExtra(EXTRA_NOISE, false)
        val channels = if (internal) 2 else 1
        val mask = if (internal) AudioFormat.CHANNEL_IN_STEREO else AudioFormat.CHANNEL_IN_MONO
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(RATE)
            .setChannelMask(mask)
            .build()
        val minBuf = AudioRecord.getMinBufferSize(RATE, mask, AudioFormat.ENCODING_PCM_16BIT)
        val bufSize = maxOf(minBuf * 4, 32768)

        val rec: AudioRecord = if (internal) {
            val mpm = getSystemService(MediaProjectionManager::class.java)
            @Suppress("DEPRECATION")
            val data: Intent = intent.getParcelableExtra(EXTRA_DATA)
                ?: throw IllegalStateException("Permesso di cattura mancante")
            val proj = mpm.getMediaProjection(intent.getIntExtra(EXTRA_CODE, 0), data)
                ?: throw IllegalStateException("Cattura non disponibile")
            proj.registerCallback(object : MediaProjection.Callback() {
                override fun onStop() {
                    finish()
                }
            }, Handler(Looper.getMainLooper()))
            projection = proj
            val cfg = AudioPlaybackCaptureConfiguration.Builder(proj)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufSize)
                .setAudioPlaybackCaptureConfig(cfg)
                .build()
        } else {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufSize)
                .build()
        }
        record = rec
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            throw IllegalStateException("Impossibile inizializzare la registrazione")
        }
        if (!internal && noiseOn && NoiseSuppressor.isAvailable()) {
            suppressor = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
        }

        val out = RandomAccessFile(File(path), "rw")
        out.setLength(0)
        out.write(ByteArray(44)) // spazio per l'intestazione WAV

        rec.startRecording()
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            out.close()
            File(path).delete()
            throw IllegalStateException("La registrazione non è partita (microfono occupato?)")
        }

        running = true
        val softClean = internal && noiseOn
        thread = Thread {
            val buf = ShortArray(bufSize / 2)
            val bytes = ByteArray(buf.size * 2)
            val filter = Cleaner(channels)
            var total = 0L
            try {
                while (running) {
                    val n = rec.read(buf, 0, buf.size)
                    if (n < 0) break
                    if (n == 0) continue
                    if (softClean) filter.process(buf, n)
                    var peak = 0
                    for (i in 0 until n) {
                        val s = buf[i].toInt()
                        val a = if (s < 0) -s else s
                        if (a > peak) peak = a
                        bytes[2 * i] = (s and 0xff).toByte()
                        bytes[2 * i + 1] = ((s shr 8) and 0xff).toByte()
                    }
                    level = peak / 32768f
                    out.write(bytes, 0, n * 2)
                    total += n * 2
                }
            } catch (e: Exception) {
                Log.e(TAG, "Errore scrittura", e)
            } finally {
                try {
                    writeHeader(out, total, channels)
                    out.close()
                } catch (e: Exception) {
                    Log.e(TAG, "Errore chiusura", e)
                }
            }
        }.also { it.start() }
    }

    /** Ferma la registrazione, chiude il file e il servizio. */
    @Synchronized
    fun finish() {
        if (finished) return
        finished = true
        cleanup()
        onStopped?.invoke()
    }

    private fun cleanup() {
        running = false
        level = 0f
        try { record?.stop() } catch (_: Exception) {}
        try { thread?.join(3000) } catch (_: Exception) {}
        try { record?.release() } catch (_: Exception) {}
        try { suppressor?.release() } catch (_: Exception) {}
        try { projection?.stop() } catch (_: Exception) {}
        record = null
        suppressor = null
        projection = null
        thread = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        instance = null
    }

    override fun onDestroy() {
        if (instance === this) finish()
        super.onDestroy()
    }

    private fun writeHeader(f: RandomAccessFile, dataLen: Long, channels: Int) {
        val byteRate = RATE * channels * 2
        val h = ByteArray(44)
        fun str(o: Int, s: String) { for (i in s.indices) h[o + i] = s[i].code.toByte() }
        fun int(o: Int, v: Long) { for (i in 0..3) h[o + i] = ((v shr (8 * i)) and 0xff).toByte() }
        fun short(o: Int, v: Int) { h[o] = (v and 0xff).toByte(); h[o + 1] = ((v shr 8) and 0xff).toByte() }
        str(0, "RIFF"); int(4, 36 + dataLen); str(8, "WAVE")
        str(12, "fmt "); int(16, 16); short(20, 1); short(22, channels)
        int(24, RATE.toLong()); int(28, byteRate.toLong())
        short(32, channels * 2); short(34, 16)
        str(36, "data"); int(40, dataLen)
        f.seek(0)
        f.write(h)
    }

    /**
     * Pulizia leggera per l'audio interno:
     * filtro passa-alto (toglie ronzii sotto ~60 Hz) + noise gate morbido
     * che abbassa il fruscio solo nei silenzi.
     */
    private class Cleaner(private val ch: Int) {
        private val a = 0.9922 // passa-alto ~60 Hz a 48 kHz
        private val prevIn = DoubleArray(ch)
        private val prevOut = DoubleArray(ch)
        private val env = DoubleArray(ch)
        private val gain = DoubleArray(ch) { 1.0 }
        private val threshold = 250.0 // circa -42 dB

        fun process(buf: ShortArray, n: Int) {
            for (i in 0 until n) {
                val c = i % ch
                val x = buf[i].toDouble()
                val y = a * (prevOut[c] + x - prevIn[c])
                prevIn[c] = x
                prevOut[c] = y
                env[c] = maxOf(abs(y), env[c] * 0.9997)
                val target = if (env[c] < threshold) 0.15 else 1.0
                gain[c] += (target - gain[c]) * (if (target > gain[c]) 0.01 else 0.0005)
                val v = (y * gain[c]).toInt().coerceIn(-32768, 32767)
                buf[i] = v.toShort()
            }
        }
    }
}
