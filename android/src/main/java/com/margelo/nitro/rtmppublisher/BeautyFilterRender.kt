package com.margelo.nitro.rtmppublisher

import android.content.Context
import android.opengl.GLES20
import android.opengl.Matrix
import android.util.Log
import com.pedro.encoder.input.gl.render.filters.BaseFilterRender
import com.pedro.encoder.utils.gl.GlUtil
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Skin-smoothing "beauty" filter built on a guided filter and a three-band
 * reconstruction, rather than the fixed blur RootEncoder's stock
 * [com.pedro.encoder.input.gl.render.filters.BeautyFilterRender] uses.
 *
 * Three passes:
 *
 *  1. `beauty_stats_fragment` — quarter-size, horizontal luma moments
 *  2. `beauty_coeff_fragment` — quarter-size, guided coefficients + skin region
 *  3. `beauty_composite_fragment` — full size, band recombination and colour
 *
 * A fixed blur cannot tell a pore from an eyelash, so smoothing enough to clear
 * blemishes also smears lashes and brows; the previous shader compensated with a
 * global unsharp mask, which then re-amplified the blemishes and cost the encoder
 * up to 13x the bitrate on a noisy frame. The guided filter separates the two by
 * local contrast instead, so each band can be treated on its own.
 *
 * The two reduced-resolution passes render into FBOs this class owns. They are
 * allocated once in [initGlFilter], resized only if the encoder dimensions
 * change, and freed in [release] — never per frame.
 *
 * ONE composite shader body, TWO precisions: [highPrecision] selects the
 * `precision highp|mediump float;` line prepended at load time. Capable GPUs get
 * highp; budget GPUs (entry Mali / PowerVR / old Adreno, which run highp fragment
 * math at half rate and have the least bandwidth to spare) and thermally-throttled
 * devices get mediump. The composite pass accumulates its variance as offsets from
 * the centre sample specifically so that mediump is safe there. The two reduced
 * passes are always highp where the device offers it — they carry the 16-bit
 * moment packing, which mediump would destroy, and at 1/16 the pixel count they
 * cost almost nothing. The precision is chosen in
 * [HybridRtmpPublisherView.applyBeautyFilter].
 */
class BeautyFilterRender(val highPrecision: Boolean) : BaseFilterRender() {
  private companion object {
    const val TAG = "BeautyFilterRender"

    /** Reduced-resolution factor for the statistics passes. */
    const val DOWNSCALE = 4

    /** Wide box radius, in reduced-resolution pixels. Must match the shaders. */
    const val WIDE_RADIUS = 4

    /** Narrow tap stride, in full-resolution pixels. Must match the shader. */
    const val NARROW_STRIDE = 2

    /**
     * Fragment shaders ask for highp only where the device advertises it.
     * `precision highp float` is a compile error on a GLES2 device without
     * GL_FRAGMENT_PRECISION_HIGH, which would take the whole filter down.
     */
    const val PREFER_HIGHP =
      "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n"
  }

  // Fullscreen quad: x, y, z, u, v per vertex (stride 20 bytes, uv at offset 3).
  private val squareVertexData = floatArrayOf(
    -1f, -1f, 0f, 0f, 0f,
    1f, -1f, 0f, 1f, 0f,
    -1f, 1f, 0f, 0f, 1f,
    1f, 1f, 0f, 1f, 1f,
  )

  private var statsProgram = -1
  private var coeffProgram = -1
  private var compositeProgram = -1
  private var blitProgram = -1

  /**
   * Set when a program fails to build. [GlUtil.createProgram] throws on a compile
   * or link failure, and the throw would surface on RootEncoder's GL thread. A
   * caught failure falls back to [blitProgram], which passes the frame through
   * untouched — the filter does nothing, rather than the seller going to black.
   */
  private var degraded = false

  private val fbo = IntArray(2)
  private val fboTex = IntArray(2)
  private var fboWidth = 0
  private var fboHeight = 0

  private val viewport = IntArray(4)

  init {
    // 4 bytes per float; layout constants are inlined to match the stock filter
    // (Kotlin can't see the Java superclass's static finals unqualified).
    squareVertex = ByteBuffer.allocateDirect(squareVertexData.size * 4)
      .order(ByteOrder.nativeOrder())
      .asFloatBuffer()
    squareVertex.put(squareVertexData).position(0)
    Matrix.setIdentityM(MVPMatrix, 0)
    Matrix.setIdentityM(STMatrix, 0)
  }

  override fun initGlFilter(context: Context) {
    // getWidth()/getHeight() are already set by the time the base class calls
    // this, so the FBOs can be sized correctly on the first frame.
    val passVertex = GlUtil.getStringFromRaw(context, R.raw.beauty_pass_vertex)
    val compositeVertex = GlUtil.getStringFromRaw(context, R.raw.beauty_composite_vertex)
    val compositePrecision =
      if (highPrecision) PREFER_HIGHP else "precision mediump float;\n"

    try {
      statsProgram = GlUtil.createProgram(
        passVertex,
        PREFER_HIGHP + GlUtil.getStringFromRaw(context, R.raw.beauty_stats_fragment)
      )
      coeffProgram = GlUtil.createProgram(
        passVertex,
        PREFER_HIGHP + GlUtil.getStringFromRaw(context, R.raw.beauty_coeff_fragment)
      )
      compositeProgram = GlUtil.createProgram(
        compositeVertex,
        compositePrecision + GlUtil.getStringFromRaw(context, R.raw.beauty_composite_fragment)
      )
    } catch (t: Throwable) {
      degraded = true
      Log.e(TAG, "beauty shaders unavailable, passing frames through", t)
    }

    try {
      blitProgram = GlUtil.createProgram(compositeVertex, BLIT_FRAGMENT)
    } catch (t: Throwable) {
      Log.e(TAG, "blit shader unavailable", t)
    }

    if (!degraded) allocateFbos(getWidth(), getHeight())
  }

  override fun drawFilter() {
    if (!degraded && ensureFbos()) {
      renderStatsPasses()
      // draw() bound its own FBO and viewport before calling us; both have to be
      // put back or the frame is rendered into our quarter-size target and lost.
      GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, getRenderHandler().getFboId()[0])
      GLES20.glViewport(0, 0, getWidth(), getHeight())
      drawComposite()
    } else {
      drawBlit()
    }
  }

  /** Passes 1 and 2, into the reduced-resolution FBOs. */
  private fun renderStatsPasses() {
    GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, viewport, 0)
    GLES20.glViewport(0, 0, fboWidth, fboHeight)

    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[0])
    GLES20.glUseProgram(statsProgram)
    bindQuad(statsProgram)
    GLES20.glUniform2f(
      GLES20.glGetUniformLocation(statsProgram, "uStep"), 1f / fboWidth, 0f
    )
    bindTexture(statsProgram, "uSrc", 0, previousTexId)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    unbindQuad(statsProgram)

    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[1])
    GLES20.glUseProgram(coeffProgram)
    bindQuad(coeffProgram)
    GLES20.glUniform2f(
      GLES20.glGetUniformLocation(coeffProgram, "uStepV"), 0f, 1f / fboHeight
    )
    GLES20.glUniform2f(
      GLES20.glGetUniformLocation(coeffProgram, "uWide"),
      WIDE_RADIUS.toFloat() / fboWidth, WIDE_RADIUS.toFloat() / fboHeight
    )
    bindTexture(coeffProgram, "uStats", 0, fboTex[0])
    bindTexture(coeffProgram, "uSrc", 1, previousTexId)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    unbindQuad(coeffProgram)

    GLES20.glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
  }

  /** Pass 3. Sets state only — the base class issues the draw call. */
  private fun drawComposite() {
    GLES20.glUseProgram(compositeProgram)
    bindQuad(compositeProgram)
    GLES20.glUniformMatrix4fv(
      GLES20.glGetUniformLocation(compositeProgram, "uMVPMatrix"), 1, false, MVPMatrix, 0
    )
    GLES20.glUniformMatrix4fv(
      GLES20.glGetUniformLocation(compositeProgram, "uSTMatrix"), 1, false, STMatrix, 0
    )
    GLES20.glUniform2f(
      GLES20.glGetUniformLocation(compositeProgram, "uTexel"),
      NARROW_STRIDE.toFloat() / getWidth(), NARROW_STRIDE.toFloat() / getHeight()
    )
    bindTexture(compositeProgram, "uSampler", 0, previousTexId)
    bindTexture(compositeProgram, "uCoeff", 1, fboTex[1])
  }

  private fun drawBlit() {
    GLES20.glUseProgram(blitProgram)
    bindQuad(blitProgram)
    GLES20.glUniformMatrix4fv(
      GLES20.glGetUniformLocation(blitProgram, "uMVPMatrix"), 1, false, MVPMatrix, 0
    )
    GLES20.glUniformMatrix4fv(
      GLES20.glGetUniformLocation(blitProgram, "uSTMatrix"), 1, false, STMatrix, 0
    )
    bindTexture(blitProgram, "uSampler", 0, previousTexId)
  }

  private fun bindQuad(program: Int) {
    val position = GLES20.glGetAttribLocation(program, "aPosition")
    val coord = GLES20.glGetAttribLocation(program, "aTextureCoord")
    squareVertex.position(0)
    GLES20.glVertexAttribPointer(position, 3, GLES20.GL_FLOAT, false, 20, squareVertex)
    GLES20.glEnableVertexAttribArray(position)
    squareVertex.position(3)
    GLES20.glVertexAttribPointer(coord, 2, GLES20.GL_FLOAT, false, 20, squareVertex)
    GLES20.glEnableVertexAttribArray(coord)
  }

  private fun unbindQuad(program: Int) {
    GlUtil.disableResources(
      GLES20.glGetAttribLocation(program, "aTextureCoord"),
      GLES20.glGetAttribLocation(program, "aPosition")
    )
  }

  private fun bindTexture(program: Int, name: String, unit: Int, texId: Int) {
    GLES20.glUniform1i(GLES20.glGetUniformLocation(program, name), unit)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId)
  }

  /** True when the reduced-resolution targets are ready for this frame size. */
  private fun ensureFbos(): Boolean {
    val w = getWidth() / DOWNSCALE
    val h = getHeight() / DOWNSCALE
    if (w < 1 || h < 1) return false
    if (w != fboWidth || h != fboHeight) allocateFbos(getWidth(), getHeight())
    return fboWidth > 0
  }

  private fun allocateFbos(srcWidth: Int, srcHeight: Int) {
    releaseFbos()
    val w = srcWidth / DOWNSCALE
    val h = srcHeight / DOWNSCALE
    if (w < 1 || h < 1) return

    GLES20.glGenFramebuffers(2, fbo, 0)
    GLES20.glGenTextures(2, fboTex, 0)
    for (i in 0 until 2) {
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fboTex[i])
      // Pass 1's output is read at 1:1 by pass 2, and its 16-bit values are split
      // across channel pairs — interpolating those would mix a high byte with a
      // neighbour's low byte, so it must be NEAREST. Pass 2's coefficients are
      // read at full resolution and want LINEAR: that bilinear upsample IS the
      // guided filter's edge-aware feathering step.
      val filter = if (i == 0) GLES20.GL_NEAREST else GLES20.GL_LINEAR
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, filter)
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, filter)
      GLES20.glTexParameteri(
        GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE
      )
      GLES20.glTexParameteri(
        GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE
      )
      GLES20.glTexImage2D(
        GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0,
        GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null
      )
      GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[i])
      GLES20.glFramebufferTexture2D(
        GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
        GLES20.GL_TEXTURE_2D, fboTex[i], 0
      )
      if (GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
        != GLES20.GL_FRAMEBUFFER_COMPLETE
      ) {
        Log.e(TAG, "incomplete FBO at ${w}x$h, passing frames through")
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        releaseFbos()
        degraded = true
        return
      }
    }
    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
    fboWidth = w
    fboHeight = h
    Log.i(TAG, "beauty FBOs ${w}x$h (source ${srcWidth}x$srcHeight)")
  }

  private fun releaseFbos() {
    if (fboWidth > 0 || fboHeight > 0 || fbo[0] != 0) {
      GLES20.glDeleteFramebuffers(2, fbo, 0)
      GLES20.glDeleteTextures(2, fboTex, 0)
      fbo.fill(0)
      fboTex.fill(0)
    }
    fboWidth = 0
    fboHeight = 0
  }

  override fun disableResources() {
    unbindQuad(if (degraded) blitProgram else compositeProgram)
  }

  override fun release() {
    releaseFbos()
    for (p in intArrayOf(statsProgram, coeffProgram, compositeProgram, blitProgram)) {
      if (p > 0) GLES20.glDeleteProgram(p)
    }
    statsProgram = -1
    coeffProgram = -1
    compositeProgram = -1
    blitProgram = -1
  }
}

private const val BLIT_FRAGMENT = """
precision mediump float;
uniform sampler2D uSampler;
varying vec2 vTextureCoord;
void main() {
  gl_FragColor = texture2D(uSampler, vTextureCoord);
}
"""
