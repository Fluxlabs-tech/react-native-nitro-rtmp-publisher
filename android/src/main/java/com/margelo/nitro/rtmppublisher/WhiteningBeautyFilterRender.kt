package com.margelo.nitro.rtmppublisher

import android.content.Context
import android.opengl.GLES20
import android.opengl.Matrix
import com.pedro.encoder.input.gl.render.filters.BaseFilterRender
import com.pedro.encoder.utils.gl.GlUtil
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Skin-smoothing "beauty" filter retuned for a BRIGHT / FAIR look instead of
 * the warm, reddish cast of RootEncoder's stock
 * [com.pedro.encoder.input.gl.render.filters.BeautyFilterRender].
 *
 * We ship our OWN shader (not the stock filter's) for two reasons: the stock
 * fragment shader is baked into the encoder AAR and can't be edited, and its
 * color tail (a saturation matrix + a darkening lift) makes skin read RED. Our
 * `res/raw/beauty_whitening_fragment.glsl` keeps the stock frequency-separation
 * smoothing 1:1 but retunes the color tail (less saturation, no darkening, a
 * luma-gated lift toward white) so faces read fair/bright. The look knobs live
 * at the top of that .glsl.
 *
 * The GL plumbing here is a 1:1 port of the stock filter — same fullscreen-quad
 * vertex layout, same uniforms, same draw call — so this is a drop-in for
 * [com.pedro.encoder.input.gl.render.filters.BeautyFilterRender].
 *
 * ONE shader body, TWO precisions: [highPrecision] selects the
 * `precision highp|mediump float;` line prepended at load time. Capable GPUs get
 * highp; budget GPUs (entry Mali / PowerVR / old Adreno, which run highp
 * fragment math at half rate and have the least bandwidth to spare) and
 * thermally-throttled devices get mediump. Texture COORDINATES stay highp in
 * both (declared in the shader) so the 24-tap blur doesn't drift. The precision
 * is chosen in [HybridRtmpPublisherView.applyBeautyFilter].
 */
class WhiteningBeautyFilterRender(val highPrecision: Boolean) : BaseFilterRender() {
  // Fullscreen quad: x, y, z, u, v per vertex (stride 20 bytes, uv at offset 3).
  private val squareVertexData = floatArrayOf(
    -1f, -1f, 0f, 0f, 0f,
    1f, -1f, 0f, 1f, 0f,
    -1f, 1f, 0f, 0f, 1f,
    1f, 1f, 0f, 1f, 1f,
  )

  private var program = -1
  private var aPositionHandle = -1
  private var aTextureHandle = -1
  private var uMVPMatrixHandle = -1
  private var uSTMatrixHandle = -1
  private var uSamplerHandle = -1
  private var uResolutionHandle = -1

  init {
    // 4 bytes per float; layout constants below are inlined to match the stock
    // filter (Kotlin can't see the Java superclass's static finals unqualified).
    squareVertex = ByteBuffer.allocateDirect(squareVertexData.size * 4)
      .order(ByteOrder.nativeOrder())
      .asFloatBuffer()
    squareVertex.put(squareVertexData).position(0)
    Matrix.setIdentityM(MVPMatrix, 0)
    Matrix.setIdentityM(STMatrix, 0)
  }

  override fun initGlFilter(context: Context) {
    // One shader body; the default float precision is chosen here and prepended.
    // Texture coordinates are pinned highp inside the shader regardless (so the
    // blur doesn't drift on the mediump build) — see the .glsl header.
    val precision = if (highPrecision) "precision highp float;\n" else "precision mediump float;\n"
    val vertexShader = GlUtil.getStringFromRaw(context, R.raw.beauty_whitening_vertex)
    val fragmentShader = precision + GlUtil.getStringFromRaw(context, R.raw.beauty_whitening_fragment)

    program = GlUtil.createProgram(vertexShader, fragmentShader)
    aPositionHandle = GLES20.glGetAttribLocation(program, "aPosition")
    aTextureHandle = GLES20.glGetAttribLocation(program, "aTextureCoord")
    uMVPMatrixHandle = GLES20.glGetUniformLocation(program, "uMVPMatrix")
    uSTMatrixHandle = GLES20.glGetUniformLocation(program, "uSTMatrix")
    uSamplerHandle = GLES20.glGetUniformLocation(program, "uSampler")
    uResolutionHandle = GLES20.glGetUniformLocation(program, "uResolution")
  }

  override fun drawFilter() {
    GLES20.glUseProgram(program)

    // Vertex layout: position at offset 0, UV at offset 3 floats, stride 20 bytes.
    squareVertex.position(0)
    GLES20.glVertexAttribPointer(aPositionHandle, 3, GLES20.GL_FLOAT, false, 20, squareVertex)
    GLES20.glEnableVertexAttribArray(aPositionHandle)

    squareVertex.position(3)
    GLES20.glVertexAttribPointer(aTextureHandle, 2, GLES20.GL_FLOAT, false, 20, squareVertex)
    GLES20.glEnableVertexAttribArray(aTextureHandle)

    GLES20.glUniformMatrix4fv(uMVPMatrixHandle, 1, false, MVPMatrix, 0)
    GLES20.glUniformMatrix4fv(uSTMatrixHandle, 1, false, STMatrix, 0)
    // Matches the stock filter: half a texel step expressed in clip-space units.
    GLES20.glUniform2f(uResolutionHandle, 2f / getWidth(), 2f / getHeight())
    GLES20.glUniform1i(uSamplerHandle, 0)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, previousTexId)
  }

  override fun disableResources() {
    GlUtil.disableResources(aTextureHandle, aPositionHandle)
  }

  override fun release() {
    GLES20.glDeleteProgram(program)
  }
}
