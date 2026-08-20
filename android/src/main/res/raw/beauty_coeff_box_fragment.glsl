uniform sampler2D uCoeff;
uniform highp vec2 uStep;

varying highp vec2 vTextureCoord;

void main() {
  vec3 center = texture2D(uCoeff, vTextureCoord).rgb;
  vec2 mean = center.rg;
  mean += 2.0 * texture2D(uCoeff, vTextureCoord - uStep * 3.5).rg;
  mean += 2.0 * texture2D(uCoeff, vTextureCoord - uStep * 1.5).rg;
  mean += 2.0 * texture2D(uCoeff, vTextureCoord + uStep * 1.5).rg;
  mean += 2.0 * texture2D(uCoeff, vTextureCoord + uStep * 3.5).rg;
  gl_FragColor = vec4(mean / 9.0, center.b, 1.0);
}
