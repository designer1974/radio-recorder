package com.designer1974.radio_recorder

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.util.Log
import java.io.File
import java.io.RandomAccessFile

/**
 * Codifica PCM 16 bit in AAC / HE-AAC dentro un file .m4a,
 * con il codificatore integrato di Android (nessuna libreria esterna).
 */
class AacEncoder(
    path: String,
    private val rate: Int,
    inChannels: Int,
    outChannels: Int,
    bitrate: Int,
    he: Boolean,
) {
    private val inCh = inChannels
    private val outCh = minOf(outChannels, inChannels).coerceAtLeast(1)
    private val codec: MediaCodec
    private val muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private val info = MediaCodec.BufferInfo()
    private var track = -1
    private var started = false
    private var frames = 0L
    private var mono = ByteArray(0)

    init {
        codec = create(he, bitrate) ?: create(false, bitrate)
            ?: throw IllegalStateException("Codifica AAC non disponibile")
    }

    private fun create(he: Boolean, bitrate: Int): MediaCodec? {
        var c: MediaCodec? = null
        return try {
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, outCh)
            fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            fmt.setInteger(
                MediaFormat.KEY_AAC_PROFILE,
                if (he) MediaCodecInfo.CodecProfileLevel.AACObjectHE
                else MediaCodecInfo.CodecProfileLevel.AACObjectLC
            )
            fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 65536)
            c = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            c.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            c.start()
            c
        } catch (e: Exception) {
            Log.w("AacEncoder", "profilo he=$he non disponibile", e)
            try { c?.release() } catch (_: Exception) {}
            null
        }
    }

    /** [pcm] = campioni 16 bit little-endian interlacciati ([inChannels] canali). */
    fun write(pcm: ByteArray, off: Int, len: Int) {
        var data = pcm
        var start = off
        var size = len
        if (outCh == 1 && inCh == 2) {
            // stereo -> mono
            val n = len / 4
            if (mono.size < n * 2) mono = ByteArray(n * 2)
            for (i in 0 until n) {
                val p = off + i * 4
                val l = (pcm[p].toInt() and 0xff) or (pcm[p + 1].toInt() shl 8)
                val r = (pcm[p + 2].toInt() and 0xff) or (pcm[p + 3].toInt() shl 8)
                val m = (l + r) / 2
                mono[i * 2] = (m and 0xff).toByte()
                mono[i * 2 + 1] = ((m shr 8) and 0xff).toByte()
            }
            data = mono; start = 0; size = n * 2
        }
        val frameBytes = outCh * 2
        var pos = start
        val end = start + size
        while (pos < end) {
            val idx = codec.dequeueInputBuffer(10_000)
            if (idx >= 0) {
                val buf = codec.getInputBuffer(idx)!!
                buf.clear()
                var n = minOf(buf.remaining(), end - pos)
                n -= n % frameBytes
                if (n <= 0) n = minOf(frameBytes, end - pos)
                buf.put(data, pos, n)
                codec.queueInputBuffer(idx, 0, n, frames * 1_000_000L / rate, 0)
                frames += n / frameBytes
                pos += n
            }
            drain(false)
        }
    }

    fun finish() {
        try {
            var tries = 0
            while (tries++ < 100) {
                val idx = codec.dequeueInputBuffer(10_000)
                if (idx >= 0) {
                    codec.queueInputBuffer(
                        idx, 0, 0, frames * 1_000_000L / rate,
                        MediaCodec.BUFFER_FLAG_END_OF_STREAM
                    )
                    break
                }
                drain(false)
            }
            drain(true)
        } catch (e: Exception) {
            Log.e("AacEncoder", "fine codifica", e)
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            try { codec.release() } catch (_: Exception) {}
            try { if (started) muxer.stop() } catch (_: Exception) {}
            try { muxer.release() } catch (_: Exception) {}
        }
    }

    private fun drain(eos: Boolean) {
        var idle = 0
        while (true) {
            val o = codec.dequeueOutputBuffer(info, if (eos) 10_000 else 0)
            when {
                o == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!eos || ++idle > 300) return
                }
                o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (!started) {
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        started = true
                    }
                }
                o >= 0 -> {
                    val b = codec.getOutputBuffer(o)!!
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) info.size = 0
                    if (info.size > 0 && started) {
                        b.position(info.offset)
                        b.limit(info.offset + info.size)
                        muxer.writeSampleData(track, b, info)
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }
}

object AudioTools {
    /** Durata in millisecondi di un file audio (m4a, wav…). */
    fun durationMs(path: String): Long {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L
        } catch (_: Exception) {
            0L
        } finally {
            try { r.release() } catch (_: Exception) {}
        }
    }

    /** WAV -> M4A. */
    fun wavToM4a(
        src: String, dst: String, bitrate: Int, channels: Int, he: Boolean,
        progress: (Double) -> Unit,
    ) {
        val f = RandomAccessFile(File(src), "r")
        try {
            // intestazione WAV: cerca "fmt " e "data"
            var ch = 2
            var rate = 48000
            var dataOff = 44L
            var dataLen = f.length() - 44
            val head = ByteArray(minOf(f.length(), 65536L).toInt())
            f.readFully(head)
            fun u32(p: Int) = (head[p].toLong() and 0xff) or ((head[p + 1].toLong() and 0xff) shl 8) or
                ((head[p + 2].toLong() and 0xff) shl 16) or ((head[p + 3].toLong() and 0xff) shl 24)
            fun u16(p: Int) = (head[p].toInt() and 0xff) or ((head[p + 1].toInt() and 0xff) shl 8)
            var p = 12
            while (p + 8 <= head.size) {
                val id = String(head, p, 4, Charsets.US_ASCII)
                val size = u32(p + 4)
                if (id == "fmt ") {
                    ch = u16(p + 10)
                    rate = u32(p + 12).toInt()
                } else if (id == "data") {
                    dataOff = p + 8L
                    dataLen = minOf(size, f.length() - dataOff)
                    if (dataLen <= 0) dataLen = f.length() - dataOff
                    break
                }
                p += 8 + size.toInt() + (size.toInt() and 1)
            }
            val enc = AacEncoder(dst, rate, ch, channels, bitrate, he)
            f.seek(dataOff)
            val buf = ByteArray(65536 - 65536 % (ch * 2))
            var done = 0L
            var lastReport = 0L
            while (done < dataLen) {
                val n = f.read(buf, 0, minOf(buf.size.toLong(), dataLen - done).toInt())
                if (n <= 0) break
                enc.write(buf, 0, n - n % (ch * 2))
                done += n
                if (done - lastReport > 2_000_000) {
                    lastReport = done
                    progress(done.toDouble() / dataLen)
                }
            }
            enc.finish()
        } finally {
            f.close()
        }
    }

    /** M4A (o altro formato) -> WAV PCM 16 bit. */
    fun toWav(src: String, dst: String, progress: (Double) -> Unit) {
        val ex = MediaExtractor()
        ex.setDataSource(src)
        var t = -1
        for (i in 0 until ex.trackCount) {
            val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
            if (mime.startsWith("audio/")) { t = i; break }
        }
        if (t < 0) { ex.release(); throw IllegalStateException("Nessuna traccia audio") }
        ex.selectTrack(t)
        val fmt = ex.getTrackFormat(t)
        val durUs = if (fmt.containsKey(MediaFormat.KEY_DURATION)) fmt.getLong(MediaFormat.KEY_DURATION) else 0L
        var rate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var ch = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val dec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME)!!)
        dec.configure(fmt, null, null, 0)
        dec.start()
        val out = RandomAccessFile(File(dst), "rw")
        out.setLength(0)
        out.write(ByteArray(44))
        val info = MediaCodec.BufferInfo()
        var tmp = ByteArray(0)
        var total = 0L
        var inDone = false
        var outDone = false
        var lastReport = 0L
        try {
            while (!outDone) {
                if (!inDone) {
                    val i = dec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val b = dec.getInputBuffer(i)!!
                        val n = ex.readSampleData(b, 0)
                        if (n < 0) {
                            dec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inDone = true
                        } else {
                            val ts = ex.sampleTime
                            dec.queueInputBuffer(i, 0, n, ts, 0)
                            ex.advance()
                            if (durUs > 0 && ts - lastReport > 5_000_000) {
                                lastReport = ts
                                progress(ts.toDouble() / durUs)
                            }
                        }
                    }
                }
                val o = dec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = dec.outputFormat
                    rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    ch = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                } else if (o >= 0) {
                    val b = dec.getOutputBuffer(o)!!
                    if (info.size > 0) {
                        if (tmp.size < info.size) tmp = ByteArray(info.size)
                        b.position(info.offset)
                        b.get(tmp, 0, info.size)
                        out.write(tmp, 0, info.size)
                        total += info.size
                    }
                    dec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outDone = true
                }
            }
            writeWavHeader(out, total, ch, rate)
        } finally {
            out.close()
            try { dec.stop() } catch (_: Exception) {}
            try { dec.release() } catch (_: Exception) {}
            ex.release()
        }
    }

    fun writeWavHeader(f: RandomAccessFile, dataLen: Long, channels: Int, rate: Int) {
        val h = ByteArray(44)
        fun str(o: Int, s: String) { for (i in s.indices) h[o + i] = s[i].code.toByte() }
        fun int(o: Int, v: Long) { for (i in 0..3) h[o + i] = ((v shr (8 * i)) and 0xff).toByte() }
        fun short(o: Int, v: Int) { h[o] = (v and 0xff).toByte(); h[o + 1] = ((v shr 8) and 0xff).toByte() }
        str(0, "RIFF"); int(4, 36 + dataLen); str(8, "WAVE")
        str(12, "fmt "); int(16, 16); short(20, 1); short(22, channels)
        int(24, rate.toLong()); int(28, rate.toLong() * channels * 2)
        short(32, channels * 2); short(34, 16)
        str(36, "data"); int(40, dataLen)
        f.seek(0)
        f.write(h)
    }
}
