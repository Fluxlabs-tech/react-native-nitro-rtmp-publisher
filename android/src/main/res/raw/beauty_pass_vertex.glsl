// Vertex shader for the two internal (offscreen) beauty passes.
//
// Deliberately has no MVP / ST matrices: those orient the camera frame and are
// applied once, by the composite pass. The internal passes render a plain
// fullscreen quad into their own FBO, so any transform here would rotate the
// statistics out of alignment with the frame they describe.

attribute vec4 aPosition;
attribute vec4 aTextureCoord;

varying highp vec2 vTextureCoord;

void main() {
  gl_Position = aPosition;
  vTextureCoord = aTextureCoord.xy;
}
