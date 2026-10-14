// 临色调色管线（Metal）。由 Electron 版的 GLSL 逐段翻译，算法完全一致：
// 预览、自动匹配、导出走的都是这一份着色器，面板上的数字就是图片实际经历的运算。
#include <metal_stdlib>
using namespace metal;

constant float3 LUMA = float3(0.2126, 0.7152, 0.0722);
constant int MAX_MASKS = 4;

struct Uniforms {
  float4 wb0, wb1, wb2;          // 白平衡矩阵三行
  float4 p0;                     // exposure, contrast, high, shadow
  float4 p1;                     // white, black, vib, sat
  float4 p2;                     // clarity, dehaze, vignette, grain
  float4 p3;                     // grainSize, sharpen, lod, viewLod
  float4 p4;                     // lutAmt, lutSize, gradeBalance, gradeBlend
  float4 p5;                     // aspect, showMask, bypass, maskCount
  float4 p6;                     // doCurve, doHsl, doGrade, -
  float4 p7;                     // imgW, imgH, -, -
  float4 region;                 // 输出对应原图的区域（左上原点，归一化）
  float4 gradeSh, gradeMid, gradeHi, gradeLum;
};

struct MaskU {
  float4 A;   // cx, cy, rx, ry
  float4 B;   // x2, y2, feather(0..1), type(0 radial,1 linear,2 luminance)
  float4 C;   // lumMin, lumMax, invert, enabled
  float4 D;   // exposure, contrast, -, -
  float4 E;   // saturation, -, -, -
  float4 wb0, wb1, wb2;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
  // 覆盖全屏的大三角形；uv 左上为 (0,0)
  float2 p = float2((vid << 1) & 2, vid & 2);
  VOut o;
  o.pos = float4(p * float2(2, -2) + float2(-1, 1), 0, 1);
  o.uv = p;
  return o;
}

static float gmod(float x, float y) { return x - y * floor(x / y); }
static float3 toLin(float3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(0.04045, c)); }
static float3 toGamma(float3 c) {
  c = max(c, 0.0);
  return mix(c * 12.92, 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

static float3 blurAt(texture2d<float> img, sampler s, float2 uv, float lod, float2 imgSize) {
  float2 o = exp2(lod) / imgSize * 0.5;
  return 0.25 * (img.sample(s, uv + float2(o.x, o.y), level(lod)).rgb + img.sample(s, uv + float2(-o.x, o.y), level(lod)).rgb
    + img.sample(s, uv + float2(o.x, -o.y), level(lod)).rgb + img.sample(s, uv + float2(-o.x, -o.y), level(lod)).rgb);
}

static uint pcg(uint v) {
  uint s = v * 747796405u + 2891336453u;
  uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
  return (w >> 22u) ^ w;
}
static float hash2(float2 p) {
  uint2 q = uint2(int2(floor(p)) + int2(100000));
  return float(pcg(q.x ^ pcg(q.y))) / 4294967295.0;
}
static float grainNoise(float2 pc) {
  float2 i = floor(pc), f = fract(pc);
  float2 u = f * f * (3.0 - 2.0 * f);
  float a = hash2(i), b = hash2(i + float2(1, 0)), c = hash2(i + float2(0, 1)), d = hash2(i + float2(1, 1));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) - 0.5;
}

static float sCurve(float x) { return x * x * (3.0 - 2.0 * x); }

static float tone(float x, constant Uniforms& u) {
  x = x + u.p0.y * (sCurve(x) - x);
  x = x + u.p0.z * x * x * (1.0 - x);
  x = x + u.p0.w * x * (1.0 - x) * (1.0 - x);
  x = x + u.p1.x * 0.3 * x * x * x;
  x = x + u.p1.y * 0.3 * (1.0 - x) * (1.0 - x) * (1.0 - x);
  return clamp(x, 0.0, 1.0);
}

static float3 setLuma(float3 c, float from, float to) {
  float3 ratio = c * (to / max(from, 1e-5));
  float3 add = c + (to - from);
  return mix(add, ratio, smoothstep(0.0, 0.05, from));
}

static float3 rgb2hsl(float3 c) {
  float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
  float l = (mx + mn) * 0.5, d = mx - mn;
  if (d < 1e-6) return float3(0, 0, l);
  float s = d / (1.0 - abs(2.0 * l - 1.0) + 1e-6);
  float h;
  if (mx == c.r) h = gmod((c.g - c.b) / d, 6.0);
  else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
  else h = (c.r - c.g) / d + 4.0;
  return float3(h * 60.0, clamp(s, 0.0, 1.0), l);
}

static float3 hsl2rgb(float3 hsl) {
  float h = gmod(hsl.x, 360.0) / 60.0;
  float c = (1.0 - abs(2.0 * hsl.z - 1.0)) * hsl.y;
  float x = c * (1.0 - abs(gmod(h, 2.0) - 1.0));
  float3 rgb;
  if (h < 1.0) rgb = float3(c, x, 0);
  else if (h < 2.0) rgb = float3(x, c, 0);
  else if (h < 3.0) rgb = float3(0, c, x);
  else if (h < 4.0) rgb = float3(0, x, c);
  else if (h < 5.0) rgb = float3(x, 0, c);
  else rgb = float3(c, 0, x);
  return rgb + (hsl.z - c * 0.5);
}

static float3 applyHsl(float3 c, texture2d<float> hslTex, sampler ls) {
  float3 hsl = rgb2hsl(c);
  if (hsl.y < 1e-4) return c;
  float3 adj = hslTex.sample(ls, float2((hsl.x + 0.5) / 360.0, 0.5)).rgb;
  float s0 = hsl.y;
  hsl.x += adj.x * 30.0;
  hsl.y = clamp(hsl.y * (1.0 + adj.y), 0.0, 1.0);
  float3 rgb = hsl2rgb(hsl);
  float y0 = dot(rgb, LUMA);
  float y1 = clamp(y0 * (1.0 + adj.z * 0.5 * s0), 0.0, 1.0);
  return setLuma(rgb, y0, y1);
}

static float3 applySaturation(float3 c, float vib, float sat) {
  float y = dot(c, LUMA);
  float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
  float s = (mx - mn) / (mx + 1e-4);
  float f = (1.0 + vib * (1.0 - s)) * (1.0 + sat);
  return y + (c - y) * f;
}

static float3 applyGrading(float3 c, constant Uniforms& u) {
  float y = clamp(dot(c, LUMA) + u.p4.z * 0.25, 0.0, 1.0);
  float e = mix(3.0, 1.0, u.p4.w);
  float ws = pow(1.0 - y, e), wh = pow(y, e);
  float wm = clamp(1.0 - ws - wh, 0.0, 1.0);
  c += ws * u.gradeSh.xyz + wm * u.gradeMid.xyz + wh * u.gradeHi.xyz;
  c += (ws * u.gradeLum.x + wm * u.gradeLum.y + wh * u.gradeLum.z) * 0.2;
  return c;
}

static float maskWeight(constant MaskU& mk, float2 p, float y, float aspect) {
  float m = 0.0, f = mk.B.z;
  if (mk.B.w < 0.5) {
    float2 d = (p - mk.A.xy) / max(mk.A.zw, float2(1e-4));
    m = 1.0 - smoothstep(max(1.0 - f, 0.0) - 1e-3, 1.0, length(d));
  } else if (mk.B.w < 1.5) {
    float2 sc = float2(aspect, 1.0);
    float2 a = mk.A.xy * sc, b = mk.B.xy * sc, q = p * sc, ab = b - a;
    float t = dot(q - a, ab) / max(dot(ab, ab), 1e-6);
    m = 1.0 - smoothstep(0.0, 1.0, t);
  } else {
    float fw = f * 0.2 + 1e-3;
    m = smoothstep(mk.C.x - fw, mk.C.x, y) * (1.0 - smoothstep(mk.C.y, mk.C.y + fw, y));
  }
  if (mk.C.z > 0.5) m = 1.0 - m;
  return m * mk.C.w;
}

static float3 applyMask(constant MaskU& mk, float3 c, float m) {
  if (m <= 0.0) return c;
  float3 lin = toLin(clamp(c, 0.0, 1.0));
  float3 w = float3(dot(mk.wb0.xyz, lin), dot(mk.wb1.xyz, lin), dot(mk.wb2.xyz, lin));
  lin = mix(lin, w, m) * exp2(mk.D.x * m);
  c = clamp(toGamma(lin), 0.0, 1.0);
  float k = mk.D.y / 100.0 * m;
  c = c + k * (float3(sCurve(c.r), sCurve(c.g), sCurve(c.b)) - c);
  float y = dot(c, LUMA);
  c = y + (c - y) * (1.0 + mk.E.x / 100.0 * m);
  return clamp(c, 0.0, 1.0);
}

fragment float4 fmain(VOut in [[stage_in]],
                      constant Uniforms& u [[buffer(0)]],
                      constant MaskU* masks [[buffer(1)]],
                      texture2d<float> img [[texture(0)]],
                      texture2d<float> curveLut [[texture(1)]],
                      texture2d<float> hslTex [[texture(2)]],
                      texture3d<float> lut3d [[texture(3)]]) {
  constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
  constexpr sampler ls(filter::linear, address::clamp_to_edge);
  constexpr sampler rs(filter::linear, s_address::repeat, t_address::clamp_to_edge);

  float2 uv = u.region.xy + in.uv * u.region.zw;
  float3 c = img.sample(s, uv).rgb;
  if (u.p5.z > 0.5) return float4(c, 1);
  float2 p = uv;
  float2 imgSize = u.p7.xy;
  float aspect = u.p5.x;
  float clarity = u.p2.x, dehaze = u.p2.y, vignette = u.p2.z, grain = u.p2.w;
  float sharpen = u.p3.y, lod = u.p3.z, viewLod = u.p3.w, high = u.p0.z;

  // 0. 低频信息（清晰度、锐化用），取自原图
  float yIn = dot(c, LUMA);
  float yBlur = clarity != 0.0 ? dot(blurAt(img, s, uv, lod, imgSize), LUMA) : 0.0;
  float ySharp = sharpen > 0.0 ? dot(blurAt(img, s, uv, viewLod + 1.0, imgSize), LUMA) : yIn;

  // 1. 白平衡（Bradford）+ 曝光，线性光；不截断，超出的高光留给第 2 步恢复
  float3 l0 = toLin(c);
  float3 lin = float3(dot(u.wb0.xyz, l0), dot(u.wb1.xyz, l0), dot(u.wb2.xyz, l0)) * exp2(u.p0.x);

  // 1b. 去雾：局部暗通道估计雾浓度（负值加一层雾）
  if (dehaze > 0.0) {
    float3 hz = toLin(blurAt(img, s, uv, lod + 1.0, imgSize));
    float veil = clamp(min(hz.r, min(hz.g, hz.b)) * dehaze * 0.9, 0.0, 0.9);
    lin = max(lin - veil, 0.0) / (1.0 - veil);
  } else if (dehaze < 0.0) {
    lin = mix(lin, float3(0.6), -dehaze * 0.45);
  }

  // 2. 色调：作用在感知亮度上，按比例回写 RGB
  c = toGamma(lin);
  float yv = dot(c, LUMA);
  float y0 = clamp(yv, 0.0, 1.0);
  float yt = tone(y0, u) + max(yv - 1.0, 0.0);
  if (clarity != 0.0) {
    float d = yIn - yBlur;
    d = d / (1.0 + 5.0 * abs(d));
    yt += clarity * 1.1 * d * 4.0 * y0 * (1.0 - y0);
  }
  if (sharpen > 0.0) {
    float d = yIn - ySharp;
    d = d / (1.0 + 8.0 * abs(d));
    yt += sharpen * 1.4 * d;
  }
  // 高光恢复：从拐点开始 1 - exp 软压缩
  float yRaw = yt;
  float knee = 1.0 - 0.3 * max(-high, 0.0);
  if (yt > knee) yt = knee + (1.0 - knee) * (1.0 - exp(-(yt - knee) / max(1.0 - knee, 1e-4)));
  c = setLuma(c, yv, yt);
  float burn = clamp((yRaw - 1.0) / 0.6, 0.0, 1.0) * (1.0 - 0.75 * max(-high, 0.0));
  c = clamp(mix(c, float3(yt), burn), 0.0, 1.0);

  // 3. 色调曲线
  if (u.p6.x > 0.5) c = float3(
    curveLut.sample(ls, float2((c.r * 255.0 + 0.5) / 256.0, 0.5)).r,
    curveLut.sample(ls, float2((c.g * 255.0 + 0.5) / 256.0, 0.5)).g,
    curveLut.sample(ls, float2((c.b * 255.0 + 0.5) / 256.0, 0.5)).b);

  // 3b. 导入的 3D LUT
  if (u.p4.x > 0.0) {
    float n = u.p4.y;
    float3 lc = lut3d.sample(ls, c * ((n - 1.0) / n) + 0.5 / n).rgb;
    c = mix(c, clamp(lc, 0.0, 1.0), u.p4.x);
  }

  // 4–6. 混色器 / 饱和度 / 颜色分级
  if (u.p6.y > 0.5) c = clamp(applyHsl(c, hslTex, rs), 0.0, 1.0);
  c = clamp(applySaturation(c, u.p1.z, u.p1.w), 0.0, 1.0);
  if (u.p6.z > 0.5) c = clamp(applyGrading(c, u), 0.0, 1.0);

  // 7. 局部蒙版
  float yl = dot(c, LUMA);
  float overlay = 0.0;
  int maskCount = int(u.p5.w), showMask = int(u.p5.y);
  for (int i = 0; i < MAX_MASKS; i++) {
    if (i >= maskCount) break;
    float m = maskWeight(masks[i], p, yl, aspect);
    c = applyMask(masks[i], c, m);
    if (i == showMask) overlay = m;
  }

  // 8. 暗角
  if (vignette != 0.0) {
    float2 d = (p - 0.5) * float2(aspect, 1.0);
    float r = length(d) / length(float2(aspect, 1.0) * 0.5);
    float w = smoothstep(0.3, 1.1, r);
    w *= w;
    c = vignette < 0.0 ? c * (1.0 + vignette * 0.85 * w) : mix(c, float3(1.0), vignette * 0.7 * w);
  }

  // 9. 颗粒
  if (grain > 0.0) {
    float gs = mix(1.0, 4.0, u.p3.x);
    float n = grainNoise(p * imgSize / gs) * 0.75 + grainNoise(p * imgSize / gs * 2.03 + 17.0) * 0.25;
    float y = dot(c, LUMA);
    c = clamp(c + n * grain * 0.16 * (0.35 + 2.6 * y * (1.0 - y)), 0.0, 1.0);
  }

  if (showMask >= 0) c = mix(c, float3(1.0, 0.15, 0.2), overlay * 0.55);
  return float4(c, 1.0);
}
