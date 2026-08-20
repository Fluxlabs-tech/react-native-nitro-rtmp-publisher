// Beauty pass 3 of 3 — three-band reconstruction, at full resolution.
//
// Splits luma into three bands and recombines them with different gains, which
// is what lets one filter smooth skin and sharpen a product in the same frame:
//
//   baseW   shading, from the wide guided filter (passes 1 and 2)
//   med     5-33px structure: skin contour, folds, product outlines
//   fine    under 5px: pores, blemishes, sensor grain, lashes
//
// The fine band means opposite things on and off skin, so it gets opposite
// treatment. On skin it is blemishes -- cut it. Off skin it is product detail --
// leave it. Perceived sharpness on skin comes from `med` instead, because that
// band holds contour rather than blemish. Measured: at a hard edge the fine band
// carries 1.5% of the edge and the medium band 4.5%, so boosting `fine` cannot
// sharpen an edge at all -- a 4x gain moved a print edge by 8%.
//
// Colour is carried through as a LUMA RATIO, so hue and saturation survive the
// smoothing untouched. The shader this replaces ran screen / lighten / soft-light
// blends per channel, which shifted colour and then needed a saturation boost to
// partly undo itself.
//
// PRECISION: the leading `precision <highp|mediump> float;` line is PREPENDED at
// load time (one body, two precisions). The variance below is accumulated as
// offsets from the centre sample rather than as E[y^2] - E[y]^2, so every
// quantity stays small and no large-value cancellation happens. That is what
// makes this pass safe in mediump -- the naive form needs ~1e-5 absolute
// accuracy on a ~0.44 value, which fp16 does not have.

uniform sampler2D uSampler;   // original frame
uniform sampler2D uCoeff;     // pass 2: (a, b, region)
uniform highp vec2 uTexel;    // narrow tap spacing, in source coordinates

// Look controls. The shader has no concept of Warm / White / Cool -- it receives
// three absolute numbers and renders them. The preset table and the intensity
// interpolation live in TypeScript, so tuning a look never needs a native build.
//
//   uTemperature  -1 cool .. 0 unshifted .. +1 warm
//   uSaturation    1.0 = the source's own chroma, untouched
//   uSkinLift      0.0 = no lift
uniform float uTemperature;
uniform float uSaturation;
uniform float uSkinLift;


// Look grade. `uLut` is a 3D colour LUT flattened into a 2D atlas: 32 slices of
// 32x32, laid out 8 across and 4 down, so texel (i,j) of slice k is the output
// for input (i/31, j/31, k/31). GLES2 has no sampler3D, so the blue axis is
// tiled and interpolated by hand; red and green come from hardware bilinear.
//
// All three looks are stacked in ONE texture, four rows each, selected by
// uLookSlot. That makes switching look a uniform change rather than a texture
// reload, so tapping between looks mid-stream cannot decode a PNG or upload a
// texture on the GL thread.
//
// uLookMix 0 skips the lookup entirely -- it is uniform across the draw, so the
// branch is coherent and costs nothing.
uniform sampler2D uLut;
uniform float uLookMix;
uniform float uLookSlot;

varying highp vec2 vTextureCoord;

const vec3 W = vec3(0.299, 0.587, 0.114);

const float EPS_NARROW = 0.006;  // below this relative contrast, smooth
const float EPS_HARD   = 0.020;  // above this, allow off-skin clarity
const float EPS_FLOOR  = 0.04;
const float SKIN_FINE  = 0.35;   // fine-band gain on flat skin
const float SKIN_MED   = 1.40;   // medium-band gain on the face
const float BG_MED     = 5.00;   // ... off the face, gated on hard contrast
const float SHOULDER   = 0.88;   // roll off above this instead of clipping

const float LUT_N     = 32.0;
const float LUT_COLS  = 8.0;
const float LUT_ROWS  = 4.0;   // rows per look
const float LUT_STACK = 12.0;  // rows in the whole atlas (LUT_ROWS * 3 looks)

vec3 lutLookup(vec3 c) {
  c = clamp(c, 0.0, 1.0);

  float b  = c.b * (LUT_N - 1.0);
  float s0 = floor(b);
  float s1 = min(s0 + 1.0, LUT_N - 1.0);
  float f  = b - s0;

  // Half-texel inset spanning N-1 texels, not the whole tile: without it
  // GL_LINEAR reaches across the tile edge into an unrelated blue slice, which
  // reads as banding at 31 specific blue values. Measured 127/255 error.
  //
  // highp, because the tile offset and the in-tile position sum to nearly 1.0
  // and mediump's absolute error there is a quarter of a texel -- enough to
  // blend a quarter of the way into the neighbouring entry.
  highp vec2 inTile =
    (c.rg * (LUT_N - 1.0) + 0.5) / (LUT_N * vec2(LUT_COLS, LUT_STACK));

  highp float row = uLookSlot * LUT_ROWS;
  highp vec2 o0 =
    vec2(mod(s0, LUT_COLS), row + floor(s0 / LUT_COLS)) / vec2(LUT_COLS, LUT_STACK);
  highp vec2 o1 =
    vec2(mod(s1, LUT_COLS), row + floor(s1 / LUT_COLS)) / vec2(LUT_COLS, LUT_STACK);

  return mix(texture2D(uLut, o0 + inTile).rgb,
             texture2D(uLut, o1 + inTile).rgb, f);
}

void main() {
  vec3 src = texture2D(uSampler, vTextureCoord).rgb;
  float y = dot(src, W);

  // 3x3 taps at stride uTexel => a 5x5 extent for 9 reads. The single-pass
  // shader this replaces took 25 reads, so the whole three-pass pipeline is
  // cheaper than what it replaces, not more expensive.
  float s1 = 0.0;
  float s2 = 0.0;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 o = uTexel * vec2(float(i), float(j));
      float d = dot(texture2D(uSampler, vTextureCoord + o).rgb, W) - y;
      s1 += d;
      s2 += d * d;
    }
  }
  float mu = s1 / 9.0;
  float mean = y + mu;
  float var = max(s2 / 9.0 - mu * mu, 0.0);
  float scale = mean * mean + EPS_FLOOR;

  // Two thresholds on the same variance. `keep` marks anything with real
  // structure, so smoothing rides (1 - keep) and lashes come through at full
  // strength. `hard` opens only on genuinely high-contrast edges -- print, a
  // product outline, a garment fold -- so off-skin clarity cannot turn fabric
  // weave or sensor grain into an artificial pattern. Weave sits near var 2e-4
  // and print near 6e-2, so one threshold separates them by two orders.
  float keep = var / (var + EPS_NARROW * scale);
  float hard = var / (var + EPS_HARD * scale);
  float baseN = keep * y + (1.0 - keep) * mean;

  vec3 co = texture2D(uCoeff, vTextureCoord).rgb;
  float baseW = co.r * y + co.g;
  float region = co.b;

  float med = baseN - baseW;
  float fine = y - baseN;

  float kf = 1.0 + (SKIN_FINE - 1.0) * region * (1.0 - keep);
  float kmBg = 1.0 + (BG_MED - 1.0) * hard;
  float km = kmBg + (SKIN_MED - kmBg) * region;
  // In low light a band boost boosts sensor noise and nothing else.
  km = 1.0 + (km - 1.0) * smoothstep(0.06, 0.25, baseW);

  float outY = baseW + med * km + fine * kf;

  // Midtone lift, zero at both ends so it cannot push anything into clipping.
  float t = clamp(outY, 0.0, 1.0);
  outY += uSkinLift * region * 4.0 * t * (1.0 - t);

  // Soft shoulder rather than a hard clamp, so highlights roll off instead of
  // flattening to a single value.
  outY = max(outY, 0.0);
  float hi = 1.0 - SHOULDER;
  if (outY > SHOULDER) {
    outY = SHOULDER + hi * (1.0 - exp(-(outY - SHOULDER) / hi));
  }

  vec3 color = src * clamp(outY / max(y, 0.03), 0.0, 3.0);

  // Warm/cool on one signed axis: opposite gains on R and B. Luma is renormalised
  // afterwards so a colour grade never doubles as an exposure change. This sits
  // after the RGB reconstruction because it needs RGB, and before the saturation
  // step below so the gamut-safe headroom clamp sees the final colour direction.
  if (uTemperature != 0.0) {
    float lumaPre = dot(color, W);
    color *= vec3(1.0 + uTemperature * 0.12, 1.0, 1.0 - uTemperature * 0.12);
    color *= lumaPre / max(dot(color, W), 1e-4);
  }

  // Boost toward uSaturation, but never past what the pixel has headroom for. A
  // flat mix above 1.0 shoves channels out of range and the final clamp then
  // flattens every vivid tone to the same value; this backs off per pixel.
  float lum = dot(color, W);
  vec3 dev = color - vec3(lum);
  vec3 room = mix(vec3(lum), vec3(1.0 - lum), step(0.0, dev));
  vec3 lim = room / max(abs(dev), 1e-4);
  float headroom = max(1.0, min(min(lim.r, lim.g), lim.b));
  color = vec3(lum) + dev * min(uSaturation, headroom);

  // The look sits after temperature and saturation because those two are the
  // base calibration the LUT was authored on top of, and before the clamp so a
  // grade that pushes slightly out of range still gets caught.
  if (uLookMix > 0.0) {
    color = mix(color, lutLookup(color), uLookMix);
  }

  gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
