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
struct ImageVertex {float2 position; float2 uv; float alpha; uint blend;};
struct ImageRaster {float4 position [[position]]; float2 uv; float alpha; uint blend [[flat]];};
vertex ImageRaster lumoImageVertex(uint id [[vertex_id]], const device ImageVertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    ImageVertex v = vertices[id];
    float2 p = (v.position-u.viewport.xy)/u.viewport.zw;
    return {float4(p.x*2-1,1-p.y*2,0,1),v.uv,v.alpha,v.blend};
}
fragment FragmentOutput lumoImageFragment(ImageRaster in [[stage_in]], texture2d<float> image [[texture(0)]], float4 destination [[color(0),raster_order_group(0)]]) {
    constexpr sampler imageSampler(coord::normalized,address::clamp_to_edge,filter::linear);
    float4 sample = image.sample(imageSampler,in.uv);
    sample.a *= in.alpha;
    return {composite(sample,destination,in.blend)};
}

struct StudyUniforms {
    float4 viewport;
    float4 values;     // thresholds (-1 when off), tone, opaque matte
    float4 texture;    // kind, strength, frequency, direction
    float4 whitespace; // normalized full-canvas rect
    float4 mask;       // normalized fitted rect
    float4 background; // RGB and blank strength
    float4 options;    // canvas aspect, mask mode
    uint4 seed;
};
float luminance(float3 c) {return dot(c,float3(0.2126,0.7152,0.0722));}
float studyHash(int2 p,uint seed) {
    uint h=uint(p.x)*0x8da6b343u ^ uint(p.y)*0xd8163841u ^ seed;
    h ^= h>>16; h *= 0x7feb352du; h ^= h>>15; h *= 0x846ca68bu; h ^= h>>16;
    return float(h & 0x00ffffffu)/16777215.0;
}
float studyNoise(float2 p,uint seed) {
    int2 i=int2(floor(p));
    float2 f=fract(p);
    f=f*f*(3-2*f);
    return mix(mix(studyHash(i,seed),studyHash(i+int2(1,0),seed),f.x),
               mix(studyHash(i+int2(0,1),seed),studyHash(i+1,seed),f.x),f.y);
}
float3 keepLuminance(float3 hue,float y) {
    float3 d=hue-luminance(hue);
    float3 room=select(float3(y),float3(1-y),d>=0);
    float3 scale=room/max(abs(d),0.000001);
    return clamp(y+d*min(1.0,min(scale.x,min(scale.y,scale.z))),0.0,1.0);
}
fragment float4 lumoStudyFragment(CompositeRaster in [[stage_in]], texture2d<float,access::read> input [[texture(0)]],
                                  texture2d<float> mask [[texture(1)]], constant StudyUniforms &u [[buffer(0)]]) {
    float4 sample=input.read(uint2(in.position.xy));
    float3 rgb=sample.rgb/max(sample.a,0.00001);
    float2 uv=u.viewport.xy+(in.position.xy/float2(input.get_width(),input.get_height()))*u.viewport.zw;

    if (u.texture.x>0 && u.texture.y>0) {
        float2 q=float2(uv.x*u.options.x,uv.y)*u.texture.z;
        float angle=u.texture.w;
        float2 p=float2(dot(q,float2(cos(angle),sin(angle))),dot(q,float2(-sin(angle),cos(angle))));
        uint seed=u.seed.x;
        float a=studyNoise(p*0.72,seed);
        float b=studyNoise(p*1.9+float2(a*2.8,-a*3.1),seed+31u);
        float c=studyNoise(p*5.8,seed+47u);
        float v=0.63*a+0.27*b+0.10*c;
        float3 tint;
        float density;
        if (u.texture.x<1.5) {
            tint=mix(float3(0.32,0.075,0.024),float3(0.77,0.43,0.20),smoothstep(0.48,0.72,v));
            density=smoothstep(0.33,0.61,v)*(0.75+0.25*c);
        } else {
            float stripe=abs(sin(p.y*2.4+2.6*a+1.2*b));
            float vein=1-smoothstep(0.07,0.35,stripe);
            tint=mix(float3(0.48,0.55,0.51),float3(0.06,0.13,0.15),vein);
            density=0.34+0.61*vein;
        }
        rgb=mix(rgb,tint,density*u.texture.y);
    }
    if (u.whitespace.z>0) {
        float2 inset=min(uv-u.whitespace.xy,u.whitespace.xy+u.whitespace.zw-uv);
        float distance=min(inset.x*u.options.x,inset.y);
        rgb=mix(rgb,u.background.rgb,smoothstep(0.0,0.025,distance)*u.background.a);
    }
    float y=luminance(rgb);
    if (u.values.z>0) {
        float3 tint=u.values.z<1.5 ? float3(0.73,0.22,0.055) :
                    u.values.z<2.5 ? float3(0.035,0.40,0.56) :
                    mix(float3(0.025,0.32,0.52),float3(0.86,0.43,0.15),smoothstep(0.10,0.68,y));
        rgb=keepLuminance(tint,y);
    }
    if (u.values.x>=0) {
        float v=toGamma(float3(y)).r;
        rgb=float3(v<u.values.x ? 0.0 : v<u.values.y ? 0.21586050 : 1.0);
    }
    float alpha=sample.a;
    if (u.options.y>0) {
        float2 p=(uv-u.mask.xy)/u.mask.zw;
        constexpr sampler maskSampler(coord::normalized,address::clamp_to_edge,filter::linear);
        float coverage=mask.sample(maskSampler,p).a;
        if (u.options.y>1.5) coverage=1-coverage;
        alpha*=all(p>=0.0) && all(p<=1.0) ? coverage : 0.0;
    }
    if (u.values.w>0) return float4(mix(float3(1),rgb,alpha),1);
    // CGImage expects sRGB bytes premultiplied by alpha, rather than gamma encoding linear premultiplication.
    return float4(toLinear(toGamma(rgb)*alpha),alpha);
}
