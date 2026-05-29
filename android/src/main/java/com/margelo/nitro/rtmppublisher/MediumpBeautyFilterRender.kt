package com.margelo.nitro.rtmppublisher

import android.content.Context
import android.opengl.GLES20
import android.opengl.Matrix
import com.pedro.encoder.input.gl.render.filters.BaseFilterRender
import com.pedro.encoder.utils.gl.GlUtil
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * A `mediump` build of RootEncoder's
 * [com.pedro.encoder.input.gl.render.filters.BeautyFilterRender], for budget
 * GPUs (entry Mali / PowerVR / old Adreno) that run `highp` fragment math at
 * half rate and have the least memory bandwidth to spare while streaming.
 *
 * The GL plumbing is a 1:1 port of the stock filter — same fullscreen-quad
 * vertex layout, same uniforms, same draw call. The ONLY difference is the
 * fragment shader (`beauty_mediump_fragment`), which keeps texture
 * coordinates `highp` (so the 24-tap blur doesn't drift) but runs the color
 * math in `mediump`. The algorithm and look are otherwise identical.
 *
 * Picked automatically on low-end devices — see
 * [HybridRtmpPublisherView.applyBeautyFilter]. Capable devices get the stock
 * highp [com.pedro.encoder.input.gl.render.filters.BeautyFilterRender].
 */
class MediumpBeautyFilterRender : BaseFilterRender() {
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
    val vertexShader = GlUtil.getStringFromRaw(context, R.raw.beauty_mediump_vertex)
    val fragmentShader = GlUtil.getStringFromRaw(context, R.raw.beauty_mediump_fragment)

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
