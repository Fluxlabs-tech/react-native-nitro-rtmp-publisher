package com.margelo.nitro.rtmppublisher

import android.content.Context
import android.graphics.BitmapFactory
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.util.Log
import com.pedro.encoder.input.gl.render.filters.BaseFilterRender
import com.pedro.encoder.utils.gl.GlUtil
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Five-pass fast guided filter with full-resolution three-band reconstruction.
 * The four analysis passes ping-pong through two quarter-resolution RGBA8
 * targets; no per-frame GL objects are allocated.
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

    const val HIGHP = "precision highp float;\n"
    const val MEDIUMP = "precision mediump float;\n"
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
  private var coeffBoxProgram = -1
  private var compositeProgram = -1
  private var blitProgram = -1
  private var activeProgram = -1
  private val uniformLocations = mutableMapOf<Int, MutableMap<String, Int>>()
  private val attributeLocations = mutableMapOf<Int, MutableMap<String, Int>>()

  /**
   * Set when a program fails to build. [GlUtil.createProgram] throws on a compile
   * or link failure, and the throw would surface on RootEncoder's GL thread. A
   * caught failure falls back to [blitProgram], which passes the frame through
   * untouched — the filter does nothing, rather than the seller going to black.
   */
  private var degraded = false

  @Volatile var enabled = true
  @Volatile var intensity = 1.0f

  /** Look strength. 0 skips the LUT lookup entirely. */
  @Volatile var lookMix = 0.0f

  /** Which LUT to sample: 0 bright, 1 cool. Warm bypasses the LUT. */
  @Volatile var lookSlot = 0.0f

  private var lutTex = 0

  private val fbo = IntArray(2)
  private val fboTex = IntArray(2)
  private var fboWidth = 0
  private var fboHeight = 0

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
    val passVertex = GlUtil.getStringFromRaw(context, R.raw.beauty_pass_vertex)
    val compositeVertex = GlUtil.getStringFromRaw(context, R.raw.beauty_composite_vertex)
    blitProgram = GlUtil.createProgram(BLIT_VERTEX, BLIT_FRAGMENT)

    if (!supportsFragmentHighp()) {
      degraded = true
      Log.w(TAG, "fragment highp unavailable, beauty disabled")
      return
    }

    try {
      statsProgram = GlUtil.createProgram(
        passVertex, HIGHP + GlUtil.getStringFromRaw(context, R.raw.beauty_stats_fragment)
      )
      coeffProgram = GlUtil.createProgram(
        passVertex, HIGHP + GlUtil.getStringFromRaw(context, R.raw.beauty_coeff_fragment)
      )
      coeffBoxProgram = GlUtil.createProgram(
        passVertex, HIGHP + GlUtil.getStringFromRaw(context, R.raw.beauty_coeff_box_fragment)
      )
      compositeProgram = GlUtil.createProgram(
        compositeVertex,
        (if (highPrecision) HIGHP else MEDIUMP) +
          GlUtil.getStringFromRaw(context, R.raw.beauty_composite_fragment)
      )
      lutTex = loadLut(context, R.raw.lut_looks)
      allocateFbos(getWidth(), getHeight())
    } catch (e: Exception) {
      degraded = true
      Log.e(TAG, "beauty shaders unavailable, passing frames through", e)
    }
  }

  override fun drawFilter() {
    if (enabled && intensity > 0f && !degraded && fboWidth > 0) {
      renderAnalysisPasses()
      restoreOutputTarget()
      drawComposite()
    } else {
      restoreOutputTarget()
      drawBlit()
    }
  }

  private fun renderAnalysisPasses() {
    GLES20.glViewport(0, 0, fboWidth, fboHeight)

    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[0])
    GLES20.glUseProgram(statsProgram)
    bindQuad(statsProgram)
    GLES20.glUniform2f(
      uniform(statsProgram, "uStep"), 1f / fboWidth, 0f
    )
    bindTexture(statsProgram, "uSrc", 0, previousTexId)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    unbindQuad(statsProgram)

    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[1])
    GLES20.glUseProgram(coeffProgram)
    bindQuad(coeffProgram)
    GLES20.glUniform2f(
      uniform(coeffProgram, "uStepV"), 0f, 1f / fboHeight
    )
    GLES20.glUniform2f(
      uniform(coeffProgram, "uWide"),
      WIDE_RADIUS.toFloat() / fboWidth, WIDE_RADIUS.toFloat() / fboHeight
    )
    bindTexture(coeffProgram, "uStats", 0, fboTex[0])
    bindTexture(coeffProgram, "uSrc", 1, previousTexId)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    unbindQuad(coeffProgram)

    renderCoefficientBox(fbo[0], fboTex[1], 1f / fboWidth, 0f)
    setTextureFilter(fboTex[0], GLES20.GL_LINEAR)
    renderCoefficientBox(fbo[1], fboTex[0], 0f, 1f / fboHeight)
    setTextureFilter(fboTex[0], GLES20.GL_NEAREST)
  }

  private fun renderCoefficientBox(targetFbo: Int, sourceTex: Int, stepX: Float, stepY: Float) {
    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, targetFbo)
    GLES20.glUseProgram(coeffBoxProgram)
    bindQuad(coeffBoxProgram)
    GLES20.glUniform2f(
      uniform(coeffBoxProgram, "uStep"), stepX, stepY
    )
    bindTexture(coeffBoxProgram, "uCoeff", 0, sourceTex)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    unbindQuad(coeffBoxProgram)
  }

  private fun restoreOutputTarget() {
    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, getRenderHandler().getFboId()[0])
    GLES20.glViewport(0, 0, getWidth(), getHeight())
  }

  /** Pass 5. Sets state only; the base class issues the draw call. */
  private fun drawComposite() {
    activeProgram = compositeProgram
    GLES20.glUseProgram(compositeProgram)
    bindQuad(compositeProgram)
    GLES20.glUniformMatrix4fv(
      uniform(compositeProgram, "uMVPMatrix"), 1, false, MVPMatrix, 0
    )
    GLES20.glUniformMatrix4fv(
      uniform(compositeProgram, "uSTMatrix"), 1, false, STMatrix, 0
    )
    GLES20.glUniform2f(
      uniform(compositeProgram, "uTexel"),
      NARROW_STRIDE.toFloat() / getWidth(), NARROW_STRIDE.toFloat() / getHeight()
    )
    GLES20.glUniform1f(
      uniform(compositeProgram, "uLookMix"),
      if (lutTex == 0) 0f else lookMix
    )
    GLES20.glUniform1f(
      uniform(compositeProgram, "uLookSlot"), lookSlot
    )
    GLES20.glUniform1f(
      uniform(compositeProgram, "uBeautyIntensity"), intensity
    )
    bindTexture(compositeProgram, "uSampler", 0, previousTexId)
    bindTexture(compositeProgram, "uCoeff", 1, fboTex[1])
    bindTexture(compositeProgram, "uLut", 2, lutTex)
  }

  private fun drawBlit() {
    activeProgram = blitProgram
    GLES20.glUseProgram(blitProgram)
    bindQuad(blitProgram)
    GLES20.glUniformMatrix4fv(
      uniform(blitProgram, "uMVPMatrix"), 1, false, MVPMatrix, 0
    )
    GLES20.glUniformMatrix4fv(
      uniform(blitProgram, "uSTMatrix"), 1, false, STMatrix, 0
    )
    bindTexture(blitProgram, "uSampler", 0, previousTexId)
  }

  private fun bindQuad(program: Int) {
    val position = attribute(program, "aPosition")
    val coord = attribute(program, "aTextureCoord")
    squareVertex.position(0)
    GLES20.glVertexAttribPointer(position, 3, GLES20.GL_FLOAT, false, 20, squareVertex)
    GLES20.glEnableVertexAttribArray(position)
    squareVertex.position(3)
    GLES20.glVertexAttribPointer(coord, 2, GLES20.GL_FLOAT, false, 20, squareVertex)
    GLES20.glEnableVertexAttribArray(coord)
  }

  private fun unbindQuad(program: Int) {
    GlUtil.disableResources(
      attribute(program, "aTextureCoord"),
      attribute(program, "aPosition")
    )
  }

  private fun bindTexture(program: Int, name: String, unit: Int, texId: Int) {
    GLES20.glUniform1i(uniform(program, name), unit)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texId)
  }

  private fun uniform(program: Int, name: String): Int =
    uniformLocations.getOrPut(program) { mutableMapOf() }
      .getOrPut(name) { GLES20.glGetUniformLocation(program, name) }

  private fun attribute(program: Int, name: String): Int =
    attributeLocations.getOrPut(program) { mutableMapOf() }
      .getOrPut(name) { GLES20.glGetAttribLocation(program, name) }

  private fun supportsFragmentHighp(): Boolean {
    val range = IntArray(2)
    val precision = IntArray(1)
    GLES20.glGetShaderPrecisionFormat(
      GLES20.GL_FRAGMENT_SHADER, GLES20.GL_HIGH_FLOAT, range, 0, precision, 0
    )
    return precision[0] > 0
  }

  private fun setTextureFilter(texture: Int, filter: Int) {
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, filter)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, filter)
  }

  /**
   * Uploads the stacked colour LUT atlas. Kept in res/raw rather than
   * res/drawable because drawable resources are density-scaled, and any resample
   * of the atlas smears colour across the tile boundaries and corrupts every
   * lookup.
   *
   * Bright and Cool live in one texture, so this runs once per filter and
   * never again -- switching look only moves [lookSlot].
   */
  private fun loadLut(context: Context, resId: Int): Int {
    val opts = BitmapFactory.Options().apply { inScaled = false }
    val bitmap = context.resources.openRawResource(resId).use {
      BitmapFactory.decodeStream(it, null, opts)
    }
    if (bitmap == null) {
      Log.e(TAG, "beauty LUT failed to decode, look disabled")
      return 0
    }
    if (bitmap.width != 256 || bitmap.height != 256) {
      Log.e(TAG, "beauty LUT must be 256x256, got ${bitmap.width}x${bitmap.height}")
      bitmap.recycle()
      return 0
    }
    val ids = IntArray(1)
    GLES20.glGenTextures(1, ids, 0)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ids[0])
    // GL_LINEAR is what makes red and green interpolate in hardware; the default
    // min filter expects mipmaps that this texture does not have.
    GLES20.glTexParameteri(
      GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR
    )
    GLES20.glTexParameteri(
      GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR
    )
    GLES20.glTexParameteri(
      GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE
    )
    GLES20.glTexParameteri(
      GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE
    )
    GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
    Log.d(TAG, "beauty LUT ${bitmap.width}x${bitmap.height}")
    bitmap.recycle()
    return ids[0]
  }

  private fun releaseLut() {
    if (lutTex != 0) {
      GLES20.glDeleteTextures(1, intArrayOf(lutTex), 0)
      lutTex = 0
    }
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
    if (activeProgram > 0) unbindQuad(activeProgram)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
  }

  override fun release() {
    releaseFbos()
    releaseLut()
    for (p in intArrayOf(
      statsProgram, coeffProgram, coeffBoxProgram, compositeProgram, blitProgram
    )) {
      if (p > 0) GLES20.glDeleteProgram(p)
    }
    statsProgram = -1
    coeffProgram = -1
    coeffBoxProgram = -1
    compositeProgram = -1
    blitProgram = -1
    activeProgram = -1
    uniformLocations.clear()
    attributeLocations.clear()
  }
}

private const val BLIT_VERTEX = """
attribute vec4 aPosition;
attribute vec4 aTextureCoord;
uniform mat4 uMVPMatrix;
uniform mat4 uSTMatrix;
varying mediump vec2 vTextureCoord;
void main() {
  gl_Position = uMVPMatrix * aPosition;
  vTextureCoord = (uSTMatrix * aTextureCoord).xy;
}
"""

private const val BLIT_FRAGMENT = """
precision mediump float;
uniform sampler2D uSampler;
varying mediump vec2 vTextureCoord;
void main() {
  gl_FragColor = texture2D(uSampler, vTextureCoord);
}
"""
