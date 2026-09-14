// Coverage-masked integer composite for ordinary presentation billboards.
// The billboard shader owns color, fog, and result alpha; this pass only
// decides whether a presentation-sprite pixel replaces the resolved world
// pixel.

#ifdef PIXEL
uniform Image u_coverage;

vec4 effect(vec4 tint, Image spriteColor, vec2 uv, vec2 screenCoords)
{
  if (Texel(u_coverage, uv).r < 0.5) discard;
  return Texel(spriteColor, uv);
}
#endif
