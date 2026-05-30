// Skin-smoothing "beauty" shader retuned for a BRIGHT / FAIR look.
//
// The skin smoothing (the 24-tap green-channel high-pass — frequency
// separation) is UNCHANGED from RootEncoder's stock beauty_fragment.glsl. Only
// the COLOR TAIL is retuned. The stock tail was built for a warm, ROSY look
// (a saturation matrix that AMPLIFIED skin + a uniform darkening lift); on most
// skin tones that reads as a RED / ruddy cast. This tail instead aims for the
// "no-makeup-needed" look our users want: gentle smoothing, REDUCED saturation
// (kills the red), and a luminance-gated lift toward WHITE on the lit areas of
// the face — so skin reads fair and bright, not red.
//
// PRECISION: the leading `precision <highp|mediump> float;` line is PREPENDED at
// load time by WhiteningBeautyFilterRender (one body, two precisions). Texture
// COORDINATES are pinned highp below regardless, so the 24-tap blur doesn't
// drift on the mediump build (mediump near 1.0 has ~1px error at 720p).

uniform sampler2D uSampler;
uniform highp vec2 uResolution;

varying highp vec2 vTextureCoord;

// ── Look knobs — these are the dials to tune the result on-device ────────────
// Defaults move the stock look from "red" toward "fair/bright". If the face is…
//   • still too red      → lower SATURATION (e.g. 0.78) and/or raise WHITEN
//   • too pale / washed  → raise SATURATION toward 1.0 and/or lower WHITEN
//   • too dark           → lower SMOOTH_GAMMA (e.g. 0.80) or raise FINAL_LIFT
//   • too blown-out      → lower WHITEN and/or FINAL_LIFT
const float LUMA_EXP     = 0.748; // how strongly the effect follows luma (stock 0.748)
const float SMOOTH_GAMMA = 0.85;  // skin midtone lift in the smoothing pass (stock 0.874; LOWER = brighter)
const float SOFTLIGHT    = 0.18;  // soft-light contrast blend (stock 0.241; LOWER = softer)
const float SATURATION   = 0.85;  // 1.0 = unchanged, <1 DESATURATES (removes the red), >1 boosts
const float WHITEN       = 0.16;  // strength of the lift toward white on lit skin — the "fair glow" (0 = off)
const float WHITEN_LO    = 0.30;  // luma where whitening starts (below this = hair/shadow/background, protected)
const float WHITEN_HI    = 0.88;  // luma where whitening reaches full strength
const float FINAL_LIFT   = 0.0;   // overall brightness ADD at the very end (stock was -0.096, i.e. a DARKEN)

const vec3 W = vec3(0.299, 0.587, 0.114);

highp vec2 blurCoordinates[24];

float hardLight(float color) {
    if (color <= 0.5) {
        color = color * color * 2.0;
    } else {
        color = 1.0 - ((1.0 - color) * (1.0 - color) * 2.0);
    }
    return color;
}

void main() {
    vec3 centralColor = texture2D(uSampler, vTextureCoord).rgb;

    blurCoordinates[0] = vTextureCoord.xy + uResolution * vec2(0.0, -10.0);
    blurCoordinates[1] = vTextureCoord.xy + uResolution * vec2(0.0, 10.0);
    blurCoordinates[2] = vTextureCoord.xy + uResolution * vec2(-10.0, 0.0);
    blurCoordinates[3] = vTextureCoord.xy + uResolution * vec2(10.0, 0.0);
    blurCoordinates[4] = vTextureCoord.xy + uResolution * vec2(5.0, -8.0);
    blurCoordinates[5] = vTextureCoord.xy + uResolution * vec2(5.0, 8.0);
    blurCoordinates[6] = vTextureCoord.xy + uResolution * vec2(-5.0, 8.0);
    blurCoordinates[7] = vTextureCoord.xy + uResolution * vec2(-5.0, -8.0);
    blurCoordinates[8] = vTextureCoord.xy + uResolution * vec2(8.0, -5.0);
    blurCoordinates[9] = vTextureCoord.xy + uResolution * vec2(8.0, 5.0);
    blurCoordinates[10] = vTextureCoord.xy + uResolution * vec2(-8.0, 5.0);
    blurCoordinates[11] = vTextureCoord.xy + uResolution * vec2(-8.0, -5.0);
    blurCoordinates[12] = vTextureCoord.xy + uResolution * vec2(0.0, -6.0);
    blurCoordinates[13] = vTextureCoord.xy + uResolution * vec2(0.0, 6.0);
    blurCoordinates[14] = vTextureCoord.xy + uResolution * vec2(6.0, 0.0);
    blurCoordinates[15] = vTextureCoord.xy + uResolution * vec2(-6.0, 0.0);
    blurCoordinates[16] = vTextureCoord.xy + uResolution * vec2(-4.0, -4.0);
    blurCoordinates[17] = vTextureCoord.xy + uResolution * vec2(-4.0, 4.0);
    blurCoordinates[18] = vTextureCoord.xy + uResolution * vec2(4.0, -4.0);
    blurCoordinates[19] = vTextureCoord.xy + uResolution * vec2(4.0, 4.0);
    blurCoordinates[20] = vTextureCoord.xy + uResolution * vec2(-2.0, -2.0);
    blurCoordinates[21] = vTextureCoord.xy + uResolution * vec2(-2.0, 2.0);
    blurCoordinates[22] = vTextureCoord.xy + uResolution * vec2(2.0, -2.0);
    blurCoordinates[23] = vTextureCoord.xy + uResolution * vec2(2.0, 2.0);

    // Low-pass of the GREEN channel only (luma proxy) — the smoothing kernel.
    float sampleColor = centralColor.g * 22.0;
    sampleColor += texture2D(uSampler, blurCoordinates[0]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[1]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[2]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[3]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[4]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[5]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[6]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[7]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[8]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[9]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[10]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[11]).g;
    sampleColor += texture2D(uSampler, blurCoordinates[12]).g * 2.0;
    sampleColor += texture2D(uSampler, blurCoordinates[13]).g * 2.0;
    sampleColor += texture2D(uSampler, blurCoordinates[14]).g * 2.0;
    sampleColor += texture2D(uSampler, blurCoordinates[15]).g * 2.0;
    sampleColor += texture2D(uSampler, blurCoordinates[16]).g * 2.0;
    sampleColor += texture2D(uSampler, blurCoordinates[17]).g * 2.0;
    sampleColor += texture2D(uSampler, blurCoordinates[18]).g * 2.0;
    sampleColor += texture2D(uSampler, blurCoordinates[19]).g * 2.0;
    sampleColor += texture2D(uSampler, blurCoordinates[20]).g * 3.0;
    sampleColor += texture2D(uSampler, blurCoordinates[21]).g * 3.0;
    sampleColor += texture2D(uSampler, blurCoordinates[22]).g * 3.0;
    sampleColor += texture2D(uSampler, blurCoordinates[23]).g * 3.0;
    sampleColor = sampleColor / 62.0;

    // High-pass detail (pores/blemishes/edges), hard-lit 5x into a blemish mask.
    float highPass = centralColor.g - sampleColor + 0.5;
    for (int i = 0; i < 5; i++) {
        highPass = hardLight(highPass);
    }

    // Luminance-gated strength: smooth/brighten the lit (skin) regions more.
    float luminance = dot(centralColor, W);
    float alpha = pow(luminance, LUMA_EXP);

    // Pull the high-frequency detail down a touch → skin smoothing.
    vec3 smoothColor = centralColor + (centralColor - vec3(highPass)) * alpha * 0.1;
    smoothColor.r = clamp(pow(smoothColor.r, SMOOTH_GAMMA), 0.0, 1.0);
    smoothColor.g = clamp(pow(smoothColor.g, SMOOTH_GAMMA), 0.0, 1.0);
    smoothColor.b = clamp(pow(smoothColor.b, SMOOTH_GAMMA), 0.0, 1.0);

    vec3 screen   = vec3(1.0) - (vec3(1.0) - smoothColor) * (vec3(1.0) - centralColor);
    vec3 lighten  = max(smoothColor, centralColor);
    vec3 softLight = 2.0 * centralColor * smoothColor + centralColor * centralColor
                     - 2.0 * centralColor * centralColor * smoothColor;

    vec3 color = mix(centralColor, screen, alpha);
    color = mix(color, lighten, alpha);
    color = mix(color, softLight, SOFTLIGHT);

    // De-redden. The stock shader did the OPPOSITE here (a saturateMatrix that
    // AMPLIFIED skin's orange/red). We blend TOWARD luminance: <1 desaturates,
    // which is what removes the red cast.
    float lum2 = dot(color, W);
    color = mix(vec3(lum2), color, SATURATION);

    // Fair glow: a luminance-gated lift toward white. Moving toward white both
    // BRIGHTENS and further DESATURATES the lit face (red -> fair), while the
    // smoothstep gate leaves dark hair / brows / background untouched.
    float whiteMask = smoothstep(WHITEN_LO, WHITEN_HI, lum2);
    color = mix(color, vec3(1.0), WHITEN * whiteMask);

    // Overall brightness. The stock shader SUBTRACTED 0.096 here, which darkened
    // the image and (crushing the small blue channel hardest) added MORE red.
    color = clamp(color + vec3(FINAL_LIFT), 0.0, 1.0);

    gl_FragColor = vec4(color, 1.0);
}
