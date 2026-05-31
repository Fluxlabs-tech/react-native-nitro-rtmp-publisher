package com.margelo.nitro.rtmppublisher

import com.pedro.encoder.input.audio.CustomAudioEffect
import kotlin.math.cos
import kotlin.math.sin

/**
 * Real-time spectral denoiser for steady background noise — fans,
 * air-conditioners, appliance hum, traffic rumble, broadband hiss.
 *
 * This is the Android mechanism behind the `noiseSuppression` prop. Installed
 * on RootEncoder's mic tap via `setCustomAudioEffect`, so it sees the raw
 * 16-bit-PCM blocks the [com.pedro.encoder.input.audio.MicrophoneManager]
 * reads from `AudioRecord`, *before* they hit the AAC encoder.
 *
 * ## Why a spectral denoiser (and not the hardware NoiseSuppressor)
 * Android's built-in `NoiseSuppressor` / `AcousticEchoCanceler` are tuned for
 * phone-call speech and leave a fair amount of low-level broadband fan hiss
 * behind. Steady fan / AC noise is *stationary* (its spectrum barely changes
 * second-to-second), which is the exact case classic spectral noise reduction
 * excels at — so `noiseSuppression` runs this instead of the OS DSP.
 *
 * ## Algorithm
 * Short-time spectral attenuation with a decision-directed (Ephraim–Malah)
 * a-priori-SNR estimate driving a Wiener gain, and an MCRA-lite noise tracker:
 *
 *   1. Window each frame with a √Hann window (analysis), FFT.
 *   2. Track the per-bin noise power with a speech-gated recursive average —
 *      it only adapts toward the current level when that bin looks
 *      noise-dominated, so steady fan energy is learned but voice/music is not
 *      mistaken for noise.
 *   3. Compute the decision-directed a-priori SNR ξ and the Wiener gain
 *      G = ξ / (1 + ξ), floored at [GAIN_FLOOR] to avoid "musical noise".
 *   4. Apply G to the spectrum, IFFT, √Hann again (synthesis), overlap-add.
 *
 * 50 %-overlapped √Hann analysis+synthesis windows multiply to a Hann window,
 * which is COLA-unity at 50 % overlap — so the overlap-add reconstructs the
 * signal with no amplitude ripple.
 *
 * ## I/O contract
 * `MicrophoneManager` wraps the returned bytes as `Frame(out, 0, size, ts)`
 * where `size` is the number of bytes it *read* (a full blocking read, i.e.
 * `pcmBuffer.length`). The processed buffer must therefore be the SAME length
 * as the input. The STFT has an inherent [frame]-sample latency, so the output
 * FIFO is primed with [frame] zero-samples per channel; every call then
 * returns exactly as many samples as it was handed. The fixed latency is one
 * frame (~21 ms at 48 kHz) — negligible for A/V sync.
 *
 * Not thread-safe by design: a single instance is only ever touched by the one
 * mic-reader thread. Toggling `noiseSuppression` swaps the whole instance out
 * via `setCustomAudioEffect`, so there is no shared mutable state to guard.
 */
class SpectralNoiseSuppressor(
  sampleRate: Int,
  private val channels: Int,
) : CustomAudioEffect() {

  // FFT size: ~21 ms at 48/44.1 kHz, ~21–32 ms at lower rates. Power of two.
  private val frame: Int = if (sampleRate <= 24_000) 512 else 1024
  private val hop: Int = frame / 2
  private val bins: Int = frame / 2 + 1

  // √Hann window — analysis AND synthesis use it; their product is a Hann
  // window, which sums to unity over 50 % overlap (perfect reconstruction).
  private val window: FloatArray = FloatArray(frame) { n ->
    Math.sqrt(0.5 - 0.5 * cos(2.0 * Math.PI * n / frame)).toFloat()
  }

  // One independent denoiser per channel (state cannot be shared — each
  // channel has its own noise floor and SNR history).
  private val lanes: Array<Lane> = Array(channels) { Lane() }

  // ─── Tunables ────────────────────────────────────────────────────────────
  // Floor on the Wiener gain. -20 dB keeps a sliver of the noise floor so the
  // residual sounds natural instead of "underwater" / musical.
  private val gainFloor = 0.1f
  private val gainFloorSq = gainFloor * gainFloor
  // Decision-directed smoothing of the a-priori SNR (Ephraim–Malah, 0.98 is
  // the canonical value — higher = smoother gain, less musical noise).
  private val ddAlpha = 0.98f
  // Power-spectrum smoothing before the noise/speech decision.
  private val psmoothAlpha = 0.8f
  // Over-subtraction: treat the noise floor as a touch louder than measured so
  // steady fan energy is removed decisively. 1.0 = pure Wiener.
  private val overSub = 1.5f
  // A bin is "noise" when its smoothed power is within this factor of the
  // tracked floor; above it we assume speech/transient and (nearly) freeze the
  // noise tracker so we never learn the voice as noise.
  private val speechSnrThresh = 2.5f
  private val noiseAdaptNoise = 0.02f   // fast-ish tracking when bin is noise
  private val noiseAdaptSpeech = 0.0008f // near-frozen while speech present
  // Frames spent purely measuring the noise floor at start-up (~bootstrap).
  // Output passes through unattenuated during this window.
  private val bootFrames = 8

  // FFT scratch (reused every frame; single-threaded so this is safe).
  private val fftRe = FloatArray(frame)
  private val fftIm = FloatArray(frame)
  private val twiddleCos: DoubleArray
  private val twiddleSin: DoubleArray
  private val bitRev: IntArray

  init {
    // Precompute bit-reversal permutation and per-stage twiddle factors.
    bitRev = IntArray(frame)
    val logN = Integer.numberOfTrailingZeros(frame)
    for (i in 0 until frame) {
      var rev = 0
      var x = i
      for (b in 0 until logN) { rev = (rev shl 1) or (x and 1); x = x shr 1 }
      bitRev[i] = rev
    }
    // One twiddle per stage (cos/sin of the base angle); the per-butterfly
    // factor is built by complex recurrence inside the transform.
    twiddleCos = DoubleArray(logN)
    twiddleSin = DoubleArray(logN)
    var len = 2
    var s = 0
    while (len <= frame) {
      val ang = -2.0 * Math.PI / len
      twiddleCos[s] = cos(ang)
      twiddleSin[s] = sin(ang)
      len = len shl 1
      s++
    }
  }

  /** Per-channel STFT state + I/O FIFOs. */
  private inner class Lane {
    val inFifo = FloatFifo(frame * 4)
    val outFifo = FloatFifo(frame * 4)
    val ola = FloatArray(frame)          // overlap-add accumulator
    val noisePsd = FloatArray(bins)      // tracked noise power per bin
    val pSmooth = FloatArray(bins)       // smoothed observed power per bin
    val prevGain = FloatArray(bins) { 1f }
    val prevGamma = FloatArray(bins) { 1f }
    var bootCount = 0                    // frames seen during bootstrap
    var primed = false                   // latency cushion injected yet?

    fun prime() {
      // Inject one frame of silence so the algorithmic latency never starves
      // the output FIFO — every process() call can then return in full.
      for (i in 0 until frame) outFifo.addOne(0f)
      primed = true
    }
  }

  override fun process(pcmBuffer: ByteArray): ByteArray {
    val totalSamples = pcmBuffer.size / 2
    if (totalSamples == 0 || channels <= 0) return pcmBuffer
    val perChannel = totalSamples / channels
    if (perChannel == 0) return pcmBuffer

    // Deinterleave bytes → per-channel float, push into each lane, run the
    // STFT, then pull the same number of samples back out.
    val out = ByteArray(pcmBuffer.size)
    val pulled = FloatArray(perChannel)
    for (ch in 0 until channels) {
      val lane = lanes[ch]
      if (!lane.primed) lane.prime()
      // Push this call's samples for this channel into the input FIFO.
      var si = ch
      var k = 0
      while (k < perChannel) {
        val lo = pcmBuffer[si * 2].toInt() and 0xFF
        val hi = pcmBuffer[si * 2 + 1].toInt()
        lane.inFifo.addOne(((hi shl 8) or lo).toShort() / 32768f)
        si += channels
        k++
      }
      // Process every full frame that is now available.
      while (lane.inFifo.size() >= frame) {
        processFrame(lane)
      }
      // Pull `perChannel` finished samples back (cushion guarantees enough).
      lane.outFifo.take(pulled, perChannel)
      // Re-interleave into the output byte buffer.
      var di = ch
      var j = 0
      while (j < perChannel) {
        val v = (pulled[j] * 32768f).toInt().coerceIn(-32768, 32767)
        out[di * 2] = (v and 0xFF).toByte()
        out[di * 2 + 1] = ((v shr 8) and 0xFF).toByte()
        di += channels
        j++
      }
    }
    return out
  }

  /** Window → FFT → spectral gain → IFFT → window → overlap-add → emit hop. */
  private fun processFrame(lane: Lane) {
    // Peek a full (overlapping) frame; only `hop` samples are consumed.
    lane.inFifo.peek(fftRe, frame)
    for (i in 0 until frame) {
      fftRe[i] *= window[i]
      fftIm[i] = 0f
    }
    fft(inverse = false)

    val boot = lane.bootCount < bootFrames
    for (k in 0 until bins) {
      val re = fftRe[k]
      val im = fftIm[k]
      val power = re * re + im * im

      if (boot) {
        // Accumulate the noise floor; leave the signal untouched.
        lane.noisePsd[k] += power
        continue
      }

      // Smoothed observed power for a stable noise/speech decision.
      val ps = psmoothAlpha * lane.pSmooth[k] + (1f - psmoothAlpha) * power
      lane.pSmooth[k] = ps

      val noise = if (lane.noisePsd[k] < 1e-12f) 1e-12f else lane.noisePsd[k]
      val speechPresent = ps > speechSnrThresh * noise
      val adapt = if (speechPresent) noiseAdaptSpeech else noiseAdaptNoise
      lane.noisePsd[k] = noise + adapt * (ps - noise)

      // Decision-directed a-priori SNR → Wiener gain.
      val effNoise = noise * overSub
      val gamma = (power / effNoise).coerceIn(1e-6f, 1000f)
      val xi = ddAlpha * lane.prevGain[k] * lane.prevGain[k] * lane.prevGamma[k] +
        (1f - ddAlpha) * maxOf(gamma - 1f, 0f)
      var gain = xi / (1f + xi)
      if (gain * gain < gainFloorSq) gain = gainFloor
      if (gain > 1f) gain = 1f
      lane.prevGain[k] = gain
      lane.prevGamma[k] = gamma

      // Apply to bin k and its conjugate-symmetric mirror (frame - k).
      fftRe[k] = re * gain
      fftIm[k] = im * gain
      if (k in 1 until frame / 2) {
        val m = frame - k
        fftRe[m] *= gain
        fftIm[m] *= gain
      }
    }

    if (boot) {
      lane.bootCount++
      if (lane.bootCount == bootFrames) {
        // Average the accumulated power into the initial noise estimate and
        // seed the smoothing buffer so the first real frame starts coherent.
        val inv = 1f / bootFrames
        for (k in 0 until bins) {
          lane.noisePsd[k] *= inv
          lane.pSmooth[k] = lane.noisePsd[k]
        }
      }
      // During bootstrap we pass the (un-gained) spectrum straight through.
    }

    fft(inverse = true)
    // Synthesis window + overlap-add; emit the leading `hop` finished samples.
    for (i in 0 until frame) lane.ola[i] += fftRe[i] * window[i]
    for (i in 0 until hop) lane.outFifo.addOne(lane.ola[i])
    // Shift the accumulator left by one hop and zero the freed tail.
    System.arraycopy(lane.ola, hop, lane.ola, 0, frame - hop)
    for (i in frame - hop until frame) lane.ola[i] = 0f
    lane.inFifo.drop(hop)
  }

  /**
   * In-place iterative radix-2 Cooley–Tukey FFT over [fftRe]/[fftIm].
   * `inverse = true` performs the IFFT (and divides by N so it's a true
   * inverse). Twiddles are accumulated by complex recurrence per stage.
   */
  private fun fft(inverse: Boolean) {
    val n = frame
    val re = fftRe
    val im = fftIm
    // Bit-reversal reorder.
    for (i in 0 until n) {
      val j = bitRev[i]
      if (i < j) {
        var t = re[i]; re[i] = re[j]; re[j] = t
        t = im[i]; im[i] = im[j]; im[j] = t
      }
    }
    var len = 2
    var stage = 0
    while (len <= n) {
      val wRe = twiddleCos[stage]
      val wIm = if (inverse) -twiddleSin[stage] else twiddleSin[stage]
      val half = len shr 1
      var i = 0
      while (i < n) {
        var curRe = 1.0
        var curIm = 0.0
        for (k in 0 until half) {
          val a = i + k
          val b = a + half
          val tRe = curRe * re[b] - curIm * im[b]
          val tIm = curRe * im[b] + curIm * re[b]
          re[b] = (re[a] - tRe).toFloat()
          im[b] = (im[a] - tIm).toFloat()
          re[a] = (re[a] + tRe).toFloat()
          im[a] = (im[a] + tIm).toFloat()
          val nextRe = curRe * wRe - curIm * wIm
          curIm = curRe * wIm + curIm * wRe
          curRe = nextRe
        }
        i += len
      }
      len = len shl 1
      stage++
    }
    if (inverse) {
      val inv = 1f / n
      for (i in 0 until n) { re[i] *= inv; im[i] *= inv }
    }
  }

  /**
   * Minimal primitive-float FIFO (no boxing): contiguous array with a live
   * region `[0, size)`. `drop`/`take` compact via arraycopy — sizes stay small
   * (a few frames), so the linear shift is cheap and keeps the hot loop
   * allocation-free.
   */
  private class FloatFifo(initial: Int) {
    private var a = FloatArray(initial)
    private var n = 0
    fun size() = n
    fun addOne(v: Float) {
      if (n + 1 > a.size) a = a.copyOf(a.size * 2)
      a[n++] = v
    }
    fun peek(dst: FloatArray, len: Int) = System.arraycopy(a, 0, dst, 0, len)
    fun drop(len: Int) {
      System.arraycopy(a, len, a, 0, n - len)
      n -= len
    }
    fun take(dst: FloatArray, len: Int) {
      System.arraycopy(a, 0, dst, 0, len)
      drop(len)
    }
  }
}
