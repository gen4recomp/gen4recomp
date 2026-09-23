// DS-shaped map/building shader. The vertex stage resolves
// each vertex's color source (literal COLOR, normalized field diffuse, or NORMAL
// lighting), computes DS lighting in camera/vector space, and forwards the
// resulting RGB. The pixel stage samples the texture, applies the exact DS
// MODULATE/DECAL combiner, and discards fragments per the exact-alpha5
// fragment-pass predicate (u_fragmentPass). In WORLD_MRT mode it also writes
// the polygon state attachment atomically with the color output. In
// presentation-sprite mode it samples world renderState for DS depth/visibility
// and applies presentation fog; the host writes that result directly with
// replace/premultiplied semantics. No fake directional light or second diffuse
// multiplication remains. This shader owns no DS render
// state (polygon ID, quantized depth, fog gate) outside WORLD_MRT mode.
//
// The vertex-lighting algebra below (computeDsLighting, dsLightContribution,
// quantizeVectorFx, signExtend, dotDiscardingPerComponent) is a direct GLSL
// transcription of tests/support/DsLighting.lua -- see that module's
// header for the authoritative GPU3D::CalculateLighting derivation this
// mirrors line for line (the emission-seeded unnormalized accumulator, the
// per-component-truncated dot product, the diffuse/specular/ambient terms in
// their native fixed-point domains, and a single clamp to 0..31 at the very
// end -- no `/31` normalization anywhere in the pipeline). ds_lighting_test
// locks the pure-Lua reference this shader mirrors. The u_mat* uniforms
// carry the effective DS material registers, normalized c/31: the field
// profile's colors -- the HGSS field engine overrides every material's
// stored color registers with the profile -- replaced wholesale by the
// sampled colors of a playing NSBMA material clip. The renderer composes
// them per draw item (effectiveMaterialColor); a static item always receives
// the profile. Each light additionally requires the polygon's light-mask
// bit: the renderer sends the draw item's 4-bit mask decoded into
// u_lightMask (one 0/1 float per light), so a light contributes only when
// the profile enables it AND the polygon's mask admits it (GBATEK
// POLYGON_ATTR light mask). u_lightVectorN carries the raw field-authored
// direction (untransformed); dsLightContribution rotates it by mat3(u_view)
// -- the same camera-only rotation applied to the vertex normal below, since
// GPU3D's NORMAL and LIGHT_VECTOR commands share one vector matrix -- before
// negating and quantizing it into the LightDirection register.
//
// The pixel-stage combiner (modulateRgb6, decalRgb6, expand5to6) is the exact
// DS integer MODULATE/DECAL combiner in its native 5-bit/6-bit domain
// (map_renderer_graphics_test.lua's modulate/decal cases lock the equations
// against hand-computed values). An untextured polygon samples `vec4(1.0)`
// rather than a dedicated synthetic-texture uniform: at 5-bit quantization
// that is exactly (31,31,31,31), which expand5to6 widens to (63,63,63), the
// identity element of both combiner equations -- no separate uniform is
// needed to reach that value.
//
// World fog is a final-resolve concern (GBATEK "3D Display - Fog": edge
// marking, then fog, over the bounded world raster) -- WORLD_MRT carries
// POLYGON_ATTR FOG_ENABLE into renderState for that resolve. Presentation
// billboards are fogged here from their sampled world visibility and host
// fragment depth; fog result alpha remains result data, not coverage.

varying vec3 v_dsColor;
varying vec2 v_spriteUv;

#ifdef VERTEX
// VertexColor is a LÖVE built-in attribute; do not redeclare it.
attribute float VertexColorSource;
attribute vec3 VertexNormal;

uniform mat4 u_proj;
uniform mat4 u_view;
uniform mat4 u_model;
uniform mat3 u_modelNormal;
uniform bool u_billboard;
uniform vec3 u_billboardCenter;
uniform vec3 u_billboardScale;

uniform bool u_lightEnabled0;
uniform bool u_lightEnabled1;
uniform bool u_lightEnabled2;
uniform bool u_lightEnabled3;
uniform vec4 u_lightMask; // polygon light-mask bits as 0/1 floats, bit i = light i
uniform vec3 u_lightVector0;
uniform vec3 u_lightVector1;
uniform vec3 u_lightVector2;
uniform vec3 u_lightVector3;
uniform vec3 u_lightColor0;
uniform vec3 u_lightColor1;
uniform vec3 u_lightColor2;
uniform vec3 u_lightColor3;
// The effective DS material registers (normalized c/31): the field profile's
// colors, replaced by a playing NSBMA clip's sampled colors.
uniform vec3 u_matDiffuse;
uniform vec3 u_matAmbient;
uniform vec3 u_matSpecular;
uniform vec3 u_matEmission;
#ifdef PRESENTATION_SPRITE
uniform bool u_presentationSprite;
uniform vec2 u_presentationScale;
uniform vec2 u_presentationOffset;
uniform vec2 u_stateSize;
#endif

// 1.0.9 domain scale shared by normals and the transformed light-direction
// register (see DsLighting.lua's header for the full derivation this block
// mirrors -- GPU3D::CalculateLighting, melonDS-emu/melonDS commit
// d3cd6164deb1f217d4b262d18af3ef9b97e536c8, src/GPU3D.cpp).
const float NORMAL_FX_SCALE = 512.0;
const float RGB5_MAX = 31.0;
const float DIFFUSE_TERM_MODULUS = 1048576.0; // 20-bit mask (0xFFFFF + 1)
const float SPEC_SQUARE_MODULUS = 1024.0;     // 10-bit mask (0x3FF + 1)
const float SPEC_RECIP_NUMERATOR = 262144.0;  // 1 << 18
const float SPEC_SHINELEVEL_MAX = 511.0;      // 9-bit clamp (0x1FF)
const float ACCUMULATOR_SHIFT = 16384.0;      // 1 << 14

// Round a normalized float vector into an integer fixed-point domain,
// matching DsLighting.quantizeVector (round to nearest, not truncate).
vec3 quantizeVectorFx(vec3 v, float scale)
{
  return floor(v * scale + 0.5);
}

// Reinterpret a value as two's-complement of the given bit width
// (GPU3D.cpp's "<< (32-bits) >> (32-bits)" sign-extension idiom).
float signExtend(float x, float bits)
{
  float range = pow(2.0, bits);
  float wrapped = mod(x, range);
  return wrapped >= range * 0.5 ? wrapped - range : wrapped;
}

// Dot product of two 1.0.9-domain vectors, with the bottom 9 bits of each
// per-component product discarded before summing (CalculateLighting: "bottom
// 9 bits are discarded after multiplying and before adding" -- not the same
// as summing raw products and shifting once).
float dotDiscardingPerComponent(vec3 a, vec3 b, float scale)
{
  vec3 terms = floor((a * b) / scale);
  return terms.x + terms.y + terms.z;
}

// One enabled light's contribution to the accumulator, added directly (the
// caller sums these as plain integers; only the final accumulator clamps).
// `rawLightVector` is the field-authored direction, not yet rotated into
// camera space -- see computeDsLighting.
vec3 dsLightContribution(vec3 normalFx9, vec3 rawLightVector, vec3 lightColorNorm,
                          vec3 diffuse5, vec3 ambient5, vec3 specular5)
{
  // LightDirection[i]: the authored direction rotated by the same
  // camera-only vector matrix as the vertex normal (GPU3D.cpp's VecMatrix is
  // shared between the NORMAL and LIGHT_VECTOR commands), then negated per
  // the LIGHT_VECTOR command handler (case 0x32: "discard bottom bits ->
  // negate -> sign-extend").
  vec3 rotated = mat3(u_view) * rawLightVector;
  vec3 lightDirectionFx9 = quantizeVectorFx(-normalize(rotated), NORMAL_FX_SCALE);

  float dot9 = dotDiscardingPerComponent(lightDirectionFx9, normalFx9, NORMAL_FX_SCALE);

  vec3 lightColor5 = floor(lightColorNorm * RGB5_MAX + 0.5);
  vec3 diffuseTerm = vec3(0.0);
  float shinelevel = 0.0;
  if (dot9 > 0.0) {
    float diffdot = signExtend(dot9, 11.0);
    diffuseTerm = mod(diffuse5 * lightColor5 * diffdot, DIFFUSE_TERM_MODULUS);

    // Specular reuses the diffuse dot, folds in the normal's Z (the DS
    // geometry engine's fixed eye direction), truncate-squares it, then
    // applies the light's precomputed reciprocal (SpecRecip). `den` is
    // recovered from lightDirectionFx9.z rather than kept as a separate
    // pre-negation intermediate: DsLighting.lua's header documents why this
    // is lossless for the unit-vector inputs this pipeline only ever sees.
    float specDot = signExtend(dot9 + normalFx9.z, 11.0);
    float squared = mod(floor((specDot * specDot) / 1024.0), SPEC_SQUARE_MODULUS);
    float den = lightDirectionFx9.z + NORMAL_FX_SCALE;
    float specRecip = den == 0.0 ? 0.0 : floor(SPEC_RECIP_NUMERATOR / den);
    shinelevel = floor((squared * specRecip) / 256.0) - NORMAL_FX_SCALE;
    if (shinelevel < 0.0) {
      shinelevel = 0.0;
    } else {
      shinelevel = signExtend(shinelevel, 14.0);
      shinelevel = clamp(shinelevel, 0.0, SPEC_SHINELEVEL_MAX);
    }
  }

  // Ambient is a plain <<9 shift, added for every enabled light regardless
  // of the diffuse gate; it is not scaled by diffuse level.
  vec3 ambientSpecularTerm = ((specular5 * shinelevel) + (ambient5 * NORMAL_FX_SCALE)) * lightColor5;
  return diffuseTerm + ambientSpecularTerm;
}

vec3 computeDsLighting(vec3 normal)
{
  vec3 normalFx9 = quantizeVectorFx(normal, NORMAL_FX_SCALE);
  vec3 diffuse5 = floor(u_matDiffuse * RGB5_MAX + 0.5);
  vec3 ambient5 = floor(u_matAmbient * RGB5_MAX + 0.5);
  vec3 specular5 = floor(u_matSpecular * RGB5_MAX + 0.5);
  vec3 emission5 = floor(u_matEmission * RGB5_MAX + 0.5);

  // The accumulator starts at MatEmission << 14, unnormalized -- not a
  // normalized 0..31 value -- and every light's contribution sums into it as
  // a plain integer; only the final result saturates to 0..31.
  vec3 acc = emission5 * ACCUMULATOR_SHIFT;

  if (u_lightEnabled0 && u_lightMask.x > 0.5)
    acc += dsLightContribution(normalFx9, u_lightVector0, u_lightColor0, diffuse5, ambient5, specular5);
  if (u_lightEnabled1 && u_lightMask.y > 0.5)
    acc += dsLightContribution(normalFx9, u_lightVector1, u_lightColor1, diffuse5, ambient5, specular5);
  if (u_lightEnabled2 && u_lightMask.z > 0.5)
    acc += dsLightContribution(normalFx9, u_lightVector2, u_lightColor2, diffuse5, ambient5, specular5);
  if (u_lightEnabled3 && u_lightMask.w > 0.5)
    acc += dsLightContribution(normalFx9, u_lightVector3, u_lightColor3, diffuse5, ambient5, specular5);

  return clamp(floor(acc / ACCUMULATOR_SHIFT), 0.0, RGB5_MAX) / RGB5_MAX;
}

vec3 quantizeRgb5(vec3 c)
{
  return floor(c * 31.0) / 31.0;
}

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
  vec3 modelNormal;
  vec3 normal;
  vec4 viewPosition;
  vec3 viewCenter = vec3(0.0);
  if (u_billboard) {
    modelNormal = VertexNormal / u_billboardScale;
    viewCenter = (u_view * vec4(u_billboardCenter, 1.0)).xyz;
    viewPosition = vec4(viewCenter + vertex_position.xyz * u_billboardScale, 1.0);
    normal = normalize(modelNormal);
  } else {
    modelNormal = u_modelNormal * VertexNormal;
    viewPosition = u_view * u_model * vertex_position;
    normal = normalize(mat3(u_view) * modelNormal);
  }
  int src = int(floor(VertexColorSource + 0.5));

  if (src == 0) {
    v_dsColor = quantizeRgb5(VertexColor.rgb);
  } else if (src == 2) {
    // COLOR_DIFFUSE: the vertex color IS the effective diffuse register
    // (the field profile, or the NSBMA colors replacing it).
    v_dsColor = quantizeRgb5(u_matDiffuse);
  } else {
    v_dsColor = quantizeRgb5(computeDsLighting(normal));
  }

  // LÖVE Canvas framebuffers are Y-inverted relative to the screen, and this
  // custom projection bypasses LÖVE's compensating flip; negate clip Y so the
  // scene renders upright (and with correct winding) into the offscreen canvas.
  vec4 clip = u_proj * viewPosition;
#ifdef PRESENTATION_SPRITE
  if (!u_presentationSprite) {
    clip.y = -clip.y;
  }
#ifdef PRESENTATION_SPRITE_LAYER
  if (u_presentationSprite) {
    clip.y = -clip.y;
  }
#endif
#else
  clip.y = -clip.y;
#endif
#ifdef PRESENTATION_SPRITE
  if (u_presentationSprite) {
    vec4 centerClip = u_proj * vec4(viewCenter, 1.0);
#ifdef PRESENTATION_SPRITE_LAYER
    centerClip.y = -centerClip.y;
#endif
    if (centerClip.w > 0.0) {
      vec2 centerNdc = centerClip.xy / centerClip.w;
      vec2 rasterCoord;
      rasterCoord = (centerNdc * 0.5 + 0.5) * u_stateSize;
      vec2 rasterCenterNdc = ((floor(rasterCoord) + 0.5) / u_stateSize) * 2.0 - 1.0;
      clip.xy += (rasterCenterNdc - centerNdc) * clip.w;
    }
  }
#endif
  v_spriteUv = clip.xy / clip.w * 0.5 + 0.5;
#ifdef PRESENTATION_SPRITE
  if (u_presentationSprite) {
    clip.xy = clip.xy * u_presentationScale + u_presentationOffset * clip.w;
  }
#endif
  return clip;
}
#endif

#ifdef PIXEL
uniform bool u_useTexture;
// 0 opaque, 1 cutout, 2 translucent, 3 mixed opaque, 4 mixed translucent --
// see the exact alpha5 discard predicates below.
uniform int u_fragmentPass;
uniform float u_polygonAlpha;  // normalized 5-bit polygon alpha
uniform int u_polygonMode;     // 0 modulation/toon, 1 decal
uniform mat3 u_texMatrix;      // normalized-UV transform (NSBTA texture SRT)
uniform sampler2D MainTex;
#ifdef WORLD_MRT
uniform float u_polygonId;
uniform bool u_polygonFogEnabled;
const float DS_DEPTH_MAX = 16777215.0;

float dsZbufferDepth(float windowDepth)
{
  float ndc = windowDepth * 2.0 - 1.0;
  int ndc14 = int(ndc * 16384.0);
  return clamp(float(ndc14 + 16383) * 512.0, 0.0, DS_DEPTH_MAX);
}
#endif
#ifdef PRESENTATION_SPRITE
uniform bool u_presentationSprite;
uniform bool u_spriteFogEnabled;
uniform Image u_renderState;
uniform vec2 u_stateSize;
uniform bool u_fogEnabled;
uniform vec3 u_fogColor;
uniform vec4 u_fogTable0;
uniform vec4 u_fogTable1;
uniform vec4 u_fogTable2;
uniform vec4 u_fogTable3;
uniform vec4 u_fogTable4;
uniform vec4 u_fogTable5;
uniform vec4 u_fogTable6;
uniform vec4 u_fogTable7;
uniform float u_fogOffsetDepth;
uniform float u_fogShift;
uniform float u_fogAlpha;
#endif

#ifdef PRESENTATION_SPRITE
const float SPRITE_DEPTH_MAX = 16777215.0;

float spriteExpand5(float value)
{
  return value <= 0.0 ? 0.0 : value * 2.0 + 1.0;
}

float spriteDepth(float windowDepth)
{
  float ndc = windowDepth * 2.0 - 1.0;
  int ndc14 = int(ndc * 16384.0);
  return clamp(float(ndc14 + 16383) * 512.0, 0.0, SPRITE_DEPTH_MAX);
}

float spriteFogTable(int index)
{
  int clamped = index;
  if (clamped < 0) clamped = 0;
  if (clamped > 31) clamped = 31;
  int group = clamped / 4;
  int component = clamped - group * 4;
  vec4 value = u_fogTable0;
  if (group == 1) value = u_fogTable1;
  else if (group == 2) value = u_fogTable2;
  else if (group == 3) value = u_fogTable3;
  else if (group == 4) value = u_fogTable4;
  else if (group == 5) value = u_fogTable5;
  else if (group == 6) value = u_fogTable6;
  else if (group == 7) value = u_fogTable7;
  if (component == 0) return value.x;
  if (component == 1) return value.y;
  if (component == 2) return value.z;
  return value.w;
}

float spriteFogDensity(float depth)
{
  if (depth < u_fogOffsetDepth) return spriteFogTable(0);
  float shifted = floor((depth - u_fogOffsetDepth) / 4.0) * pow(2.0, u_fogShift);
  float index = floor(shifted / 131072.0);
  if (index >= 32.0) {
    index = 32.0;
    shifted = 32.0 * 131072.0;
  }
  float fraction = shifted - index * 131072.0;
  float lo = spriteFogTable(int(index));
  float hi = spriteFogTable(int(index) + 1);
  float density = floor((lo * (131072.0 - fraction) + hi * fraction) / 131072.0);
  return density >= 127.0 ? 128.0 : density;
}

vec4 fogSprite(vec4 source, float depth)
{
  if (!u_fogEnabled || !u_spriteFogEnabled) return source;
  float density = spriteFogDensity(depth);
  vec3 fog5 = floor(u_fogColor * 31.0 + 0.5);
  vec3 fog6 = vec3(spriteExpand5(fog5.x), spriteExpand5(fog5.y), spriteExpand5(fog5.z));
  vec3 source6 = floor(source.rgb * 63.0 + 0.5);
  vec3 rgb6 = floor((fog6 * density + source6 * (128.0 - density)) / 128.0);
  float alpha5 = floor(source.a * 31.0 + 0.5);
  float outAlpha5 = floor((u_fogAlpha * density + alpha5 * (128.0 - density)) / 128.0);
  return vec4(rgb6 / 63.0, outAlpha5 / 31.0);
}
#endif

// 5-bit (0-31) color component -> the combiner's 6-bit (0-63) domain
// (melonDS GPU3D_Soft.cpp color conversion): 0 stays 0, any non-zero n
// becomes 2n+1.
float expand5to6(float c5)
{
  return c5 <= 0.0 ? 0.0 : c5 * 2.0 + 1.0;
}

vec3 expand5to6v(vec3 c5)
{
  return vec3(expand5to6(c5.x), expand5to6(c5.y), expand5to6(c5.z));
}

// MODULATE, one RGB component, in the 6-bit (0-63) combiner domain.
float modulateComponent6(float texture6, float vertex6)
{
  return floor(((texture6 + 1.0) * (vertex6 + 1.0) - 1.0) / 64.0);
}

vec3 modulateRgb6(vec3 texture6, vec3 vertex6)
{
  return vec3(
    modulateComponent6(texture6.x, vertex6.x),
    modulateComponent6(texture6.y, vertex6.y),
    modulateComponent6(texture6.z, vertex6.z)
  );
}

// DECAL RGB triple, 6-bit domain: texture alpha 0 -> vertex, 31 -> texture,
// otherwise a texture-alpha-weighted interpolation. melonDS computes
// ((texture6 * textureAlpha5) + (vertex6 * (31 - textureAlpha5))) >> 5, i.e.
// a truncating divide by 32, not 31.
vec3 decalRgb6(vec3 texture6, vec3 vertex6, float textureAlpha5)
{
  if (textureAlpha5 <= 0.5) {
    return vertex6;
  }
  if (textureAlpha5 >= 30.5) {
    return texture6;
  }
  return floor((texture6 * textureAlpha5 + vertex6 * (31.0 - textureAlpha5)) / 32.0);
}

// WORLD_MRT writes active world color plus renderState: R is polygon ID, G is
// DS-quantized depth, B is the polygon fog gate, and A is the cleared or
// compositor-maintained translucent ID state.

void effect()
{
  vec2 uv = (u_texMatrix * vec3(VaryingTexCoord.xy, 1.0)).xy;
  vec4 base = u_useTexture ? Texel(MainTex, uv) : vec4(1.0);

  // Both operands enter the combiner as 5-bit components widened to the
  // 6-bit domain (expand5to6); v_dsColor already arrived
  // 5-bit-quantized from the vertex stage (quantizeRgb5).
  vec3 texture5 = floor(base.rgb * 31.0 + 0.5);
  vec3 vertex5 = floor(v_dsColor * 31.0 + 0.5);
  vec3 texture6 = expand5to6v(texture5);
  vec3 vertex6 = expand5to6v(vertex5);

  float textureAlpha5 = floor(base.a * 31.0 + 0.5);
  int polygonAlpha5 = int(floor(u_polygonAlpha * 31.0 + 0.5));

  vec3 outRgb6;
  int outputAlpha5;
  if (u_polygonMode == 1) {
    // DECAL: polygon alpha unconditionally; RGB blended by texture alpha.
    outRgb6 = decalRgb6(texture6, vertex6, textureAlpha5);
    outputAlpha5 = polygonAlpha5;
  } else {
    // MODULATE: exact DS integer-domain equations.
    outRgb6 = modulateRgb6(texture6, vertex6);
    outputAlpha5 = int(floor(float((int(textureAlpha5) + 1) * (polygonAlpha5 + 1) - 1) / 32.0));
  }
  // Exact integer-domain alpha5 discard predicates -- never a float-epsilon
  // comparison once outputAlpha5 is already computed exactly. Mixed materials
  // split their opaque and translucent texels by this exact value.
  if (u_fragmentPass == 1) {
    if (outputAlpha5 == 0) discard;
  } else if (u_fragmentPass == 2) {
    if (outputAlpha5 == 0) discard;
  } else if (u_fragmentPass == 3) {
    if (outputAlpha5 != 31) discard;
  } else if (u_fragmentPass == 4) {
    if (outputAlpha5 == 0 || outputAlpha5 == 31) discard;
  }

  vec3 outRgb = outRgb6 / 63.0;
  float alpha = float(outputAlpha5) / 31.0;

#ifdef PRESENTATION_SPRITE
  if (u_presentationSprite) {
    // Render-state and presentation sprite canvases share the offscreen
    // canvas orientation. The direct host path, retained for shader
    // compatibility, uses the opposite presentation orientation.
    if (v_spriteUv.x < 0.0 || v_spriteUv.x > 1.0 || v_spriteUv.y < 0.0 || v_spriteUv.y > 1.0) discard;
#ifdef PRESENTATION_SPRITE_LAYER
    vec2 stateUv = v_spriteUv;
#else
    vec2 stateUv = vec2(v_spriteUv.x, 1.0 - v_spriteUv.y);
#endif
    stateUv = clamp(stateUv, vec2(0.0), vec2(1.0) - 0.5 / u_stateSize);
    float worldDepth = Texel(u_renderState, stateUv).g;
    float spriteDepthValue = spriteDepth(gl_FragCoord.z);
    // Exact alpha5 discard happened above. Sampled world DS depth and host
    // sprite depth are the presentation visibility gates; host depth also
    // orders presentation sprites against one another.
    if (spriteDepthValue >= worldDepth) discard;
    vec4 fogged = fogSprite(vec4(outRgb, alpha), spriteDepthValue);
    // Replace/premultiplied presentation blending preserves fogged RGB even
    // when DS fog produces result alpha zero.
    outRgb = fogged.rgb;
    alpha = fogged.a;
  }
#endif

#ifdef PRESENTATION_SPRITE_LAYER
  love_Canvases[0] = vec4(outRgb, alpha);
  love_Canvases[1] = vec4(1.0);
#elif defined(WORLD_MRT)
  love_Canvases[0] = vec4(outRgb, alpha);
  love_Canvases[1] = vec4(u_polygonId, dsZbufferDepth(gl_FragCoord.z), u_polygonFogEnabled ? 1.0 : 0.0, 0.0);
#else
  love_Canvases[0] = vec4(outRgb, alpha);
#endif
}
#endif
