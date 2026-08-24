// Beauty pass 1 of 5: horizontal luma statistics at reduced resolution.
//
// Renders into a quarter-size FBO. Each output pixel accumulates 9 samples
// spaced one output pixel apart, giving the horizontal half of a box over a
// 33x33 source region. This is the subsampled-statistics step of the fast
// guided filter: the coefficients only need to be smooth, so computing them at
// 1/16 the pixel count costs nothing visible and is what makes the whole thing
// cheaper than the single-pass shader it replaces.
//
// Both moments are written as 16-bit values split across two 8-bit channels.
// At 8 bits this does not work at all: mean(y) and mean(y^2) are both ~0.44 on
// skin and the variance is their ~6e-5 difference, which is an order of
// magnitude below the 3.9e-3 quantisation step, so `var` comes out random and
// frequently negative. The second moment is also taken about 0.5 and scaled to
// fill the range, which keeps both terms near 0.026 instead of 0.44 and buys
// roughly another 4x of headroom for free.
//
// Pass 2 reads this at 1:1 with GL_NEAREST, so the split decodes exactly.

uniform sampler2D uSrc;
uniform vec2 uStep;      // one output pixel, in source texture coordinates

varying highp vec2 vTextureCoord;

const vec3 W = vec3(0.299, 0.587, 0.114);

void main() {
  float s1 = 0.0;
  float s2 = 0.0;
  for (int k = -4; k <= 4; k++) {
    float v = dot(texture2D(uSrc, vTextureCoord + uStep * float(k)).rgb, W);
    float d = v - 0.5;
    s1 += v;
    s2 += d * d;
  }
  float m1 = s1 / 9.0;
  float m2 = clamp(s2 / 9.0 * 4.0, 0.0, 1.0);

  float h1 = floor(m1 * 255.0) / 255.0;
  float h2 = floor(m2 * 255.0) / 255.0;
  gl_FragColor = vec4(h1, (m1 - h1) * 255.0, h2, (m2 - h2) * 255.0);
}
