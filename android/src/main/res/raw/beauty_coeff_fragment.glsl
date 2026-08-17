// Beauty pass 2 of 3 — guided-filter coefficients and the skin region.
//
// Completes the box started by pass 1 (vertical half), turns the two moments
// into the guided filter's linear model, and classifies the region. Runs at
// quarter size, so everything here is 1/16 of a full-resolution pass.
//
// GUIDED FILTER, in one line: fit q = a*y + b to the local window. In a flat
// region the variance is small, `a` goes to 0 and the output is the local mean
// (heavy smoothing). At an edge the variance is large, `a` goes to 1 and the
// output is the input (no smoothing at all). That is the whole reason this
// replaces a fixed blur: eyelashes and brow hairs are edges, so they survive
// untouched, while the pores next to them are flattened.
//
// eps scales with the local mean, which makes the threshold a RELATIVE contrast
// rather than an absolute one. Without that, the same setting means a different
// perceived strength on deep and light skin.

uniform sampler2D uStats;   // pass 1 output, sampled 1:1
uniform sampler2D uSrc;     // original frame, for the region test
uniform vec2 uStepV;        // one output pixel vertically, in uStats coords
uniform vec2 uWide;         // region tap spacing, in source coordinates

varying vec2 vTextureCoord;

const vec3 W = vec3(0.299, 0.587, 0.114);

const float EPS_WIDE = 0.060;
const float EPS_FLOOR = 0.04;

// Skin locus in normalised chromaticity r = R/(R+G+B), g = G/(R+G+B).
//
// Not YCbCr. Cb and Cr are absolute chroma differences, so they shrink as luma
// falls: measured across a 2.8x exposure range they move by 2-3x, while these
// normalised coordinates are identical to three decimals. With a Cb/Cr skin box
// a deep skin tone scored 0.63 mask coverage against 1.00 for a light tone --
// the filter quietly did less for darker-skinned sellers, and less again in a
// dim room.
//
// Skin across tones is also a LINE here, not a point: deeper skin sits at higher
// r and lower g. Measured tone samples land at (0.412, 0.320), (0.440, 0.312)
// and (0.469, 0.297). So the test is distance from that segment. For reference,
// neutral grey sits 0.016 off the locus and a painted wall 0.027.
const vec2 LOCUS_O = vec2(0.405, 0.323);
const vec2 LOCUS_U = vec2(0.933, -0.361);
const vec2 LOCUS_N = vec2(0.361, 0.933);
const float LOCUS_LEN = 0.0804;
const float MASK_LO = 0.008;
const float MASK_HI = 0.016;

float skinRegion(vec3 c) {
  float s = max(c.r + c.g + c.b, 1e-4);
  vec2 p = vec2(c.r / s, c.g / s) - LOCUS_O;
  float perp = abs(dot(p, LOCUS_N));
  float along = dot(p, LOCUS_U) / LOCUS_LEN;
  float lum = dot(c, W);

  float m = 1.0 - smoothstep(MASK_LO, MASK_HI, perp);
  m *= 1.0 - smoothstep(1.6, 2.4, abs(along - 0.5));   // tone range, generous
  // Only for crushed blacks, where chromaticity is noise. Hair and brows are
  // achromatic and the locus test already rejects them, so this stays low --
  // set it any higher and deep skin, at luma ~0.22, falls out of the mask.
  m *= smoothstep(0.03, 0.09, lum);
  m *= 1.0 - smoothstep(0.94, 0.995, lum);             // blown highlights
  return m;
}

void main() {
  float m1 = 0.0;
  float m2 = 0.0;
  for (int k = -4; k <= 4; k++) {
    vec4 t = texture2D(uStats, vTextureCoord + uStepV * float(k));
    m1 += t.r + t.g / 255.0;
    m2 += t.b + t.a / 255.0;
  }
  m1 = m1 / 9.0;
  m2 = m2 / 9.0 * 0.25;

  float d = m1 - 0.5;
  float var = max(m2 - d * d, 0.0);
  float a = var / (var + EPS_WIDE * (m1 * m1 + EPS_FLOOR));
  float b = (1.0 - a) * m1;

  // Window-averaged colour, straight off the source. Classifying the AVERAGE
  // rather than each pixel is what makes brows, lashes and lips count as face:
  // individually they are dark and achromatic, so a per-pixel test calls them
  // background and hands them the background's clarity gain, which rings their
  // inner edge. It also removes the chromaticity noise that made a per-pixel
  // test collapse on deep skin. At quarter size these 9 taps cost about half of
  // one full-resolution texture read.
  vec3 acc = vec3(0.0);
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      acc += texture2D(uSrc, vTextureCoord + uWide * vec2(float(i), float(j))).rgb;
    }
  }

  gl_FragColor = vec4(a, b, skinRegion(acc / 9.0), 1.0);
}
