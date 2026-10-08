#include <metal_stdlib>
using namespace metal;
struct Vertex { float2 position; float4 color; uint blend; };
struct Uniforms { float4 viewport; };
struct Raster { float4 position [[position]]; float4 color; uint blend [[flat]]; };
struct FragmentOutput { float4 color [[color(0), raster_order_group(0)]]; };
vertex Raster lumoVertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Vertex v = vertices[id];
    float2 p = (v.position - u.viewport.xy) / u.viewport.zw;
    return { float4(p.x * 2 - 1, 1 - p.y * 2, 0, 1), v.color, v.blend };
}
float3 toGamma(float3 c) {return select(c*12.92,1.055*pow(max(c,0.0),float3(1.0/2.4))-0.055,c>0.0031308);}
float3 toLinear(float3 c) {return select(c/12.92,pow((max(c,0.0)+0.055)/1.055,float3(2.4)),c>0.04045);}
float3 blendColor(float3 base, float3 source, uint mode) {
    if (mode == 0) return source;
    float3 b = toGamma(base), s = toGamma(source), result;
    switch (mode) {
        case 1: result = b*s; break;
        case 2: result = b+s-b*s; break;
        case 3: result = select(2*b*s,1-2*(1-b)*(1-s),b>0.5); break;
        default: {
            float3 d = select(((16*b-12)*b+4)*b,sqrt(max(b,0.0)),b>0.25);
            result = select(b-(1-2*s)*b*(1-b),b+(2*s-1)*(d-b),s>0.5);
        }
    }
    return toLinear(clamp(result,0.0,1.0));
}
// Straight source over a premultiplied destination, including transparent layer targets.
float4 composite(float4 source, float4 destination, uint mode) {
    float sa = clamp(source.a,0.0,1.0), da = destination.a;
    float3 base = destination.rgb/max(da,0.00001);
    float3 rgb = source.rgb*sa*(1-da)+blendColor(base,source.rgb,mode)*sa*da+destination.rgb*(1-sa);
    return float4(rgb,sa+da*(1-sa));
}
fragment FragmentOutput lumoFragment(Raster in [[stage_in]], float4 destination [[color(0), raster_order_group(0)]]) {
    return {composite(in.color,destination,in.blend)};
}
struct CompositeRaster {float4 position [[position]];};
vertex CompositeRaster lumoCompositeVertex(uint id [[vertex_id]]) {
    const float2 points[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    return {float4(points[id],0,1)};
}
struct LayerUniforms {float opacity; uint blend;};
fragment FragmentOutput lumoCompositeFragment(CompositeRaster in [[stage_in]], texture2d<float,access::read> layer [[texture(0)]], constant LayerUniforms &u [[buffer(0)]], float4 destination [[color(0),raster_order_group(0)]]) {
    float4 sample = layer.read(uint2(in.position.xy));
    float4 source = float4(sample.rgb/max(sample.a,0.00001),sample.a*u.opacity);
    return {composite(source,destination,u.blend)};
}
