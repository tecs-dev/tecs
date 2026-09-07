// The original twelve world-anchored hemisphere samples and edge-aware blur.
struct View { projection:mat4x4<f32>, inverse:mat4x4<f32>, tuning:vec4<f32>, camera:vec4<f32>, }
@group(0) @binding(0) var normalTexture:texture_2d<f32>;
@group(0) @binding(1) var depthTexture:texture_depth_2d;
@group(0) @binding(2) var aoTexture:texture_2d<f32>;
@group(0) @binding(3) var imageSampler:sampler;
@group(0) @binding(4) var<uniform> view:View;
@group(0) @binding(5) var sceneTexture:texture_2d<f32>;
@group(0) @binding(6) var ambientTexture:texture_2d<f32>;
struct Vertex { @builtin(position) position:vec4<f32>, @location(0) uv:vec2<f32>, }
@vertex fn vertexMain(@builtin(vertex_index) i:u32) -> Vertex {
    let uv=vec2<f32>(f32((i<<1u)&2u),f32(i&2u));
    return Vertex(vec4<f32>(uv*vec2<f32>(2.0,-2.0)+vec2<f32>(-1.0,1.0),0.0,1.0),uv);
}
fn depthAt(uv:vec2<f32>) -> f32 {
    let size=vec2<i32>(textureDimensions(depthTexture));
    return textureLoad(depthTexture,clamp(vec2<i32>(uv*vec2<f32>(size)),vec2<i32>(0),size-1),0);
}
fn worldOf(uv:vec2<f32>,depth:f32) -> vec3<f32> {
    let world=view.inverse*vec4<f32>(uv.x*2.0-1.0,1.0-uv.y*2.0,depth,1.0);
    return world.xyz/max(abs(world.w),0.000001)*sign(world.w);
}
fn hash12(value:vec2<f32>) -> f32 {
    var p=fract(vec3<f32>(value.x,value.y,value.x)*0.1031);
    p+=dot(p,p.yzx+33.33);
    return fract((p.x+p.y)*p.z);
}
@fragment fn estimate(v:Vertex) -> @location(0) f32 {
    let encoded=textureSampleLevel(normalTexture,imageSampler,v.uv,0.0);
    let depth=depthAt(v.uv);
    if(encoded.a==0.0 || depth>=1.0) { return 1.0; }
    let position=worldOf(v.uv,depth); let normal=normalize(encoded.xyz*2.0-1.0);
    let seed=hash12(position.xy*17.0+vec2<f32>(position.z*11.0,position.z*23.0));
    let random=normalize(vec3<f32>(cos(seed*6.2831853),sin(seed*6.2831853),fract(seed*17.0)*2.0-1.0));
    var tangent=random-normal*dot(random,normal);
    if(dot(tangent,tangent)<0.00001) { tangent=select(cross(normal,vec3<f32>(0.0,1.0,0.0)),cross(normal,vec3<f32>(0.0,0.0,1.0)),abs(normal.z)<0.9); }
    tangent=normalize(tangent); let bitangent=cross(normal,tangent);
    let radius=view.tuning.x; var occluded=0.0; var valid=0.0;
    for(var i=0u;i<12u;i++) {
        let progress=(f32(i)+0.5)/12.0; let angle=f32(i)*2.39996323+seed*6.2831853;
        let elevation=mix(0.15,0.95,fract(progress*7.61803399)); let radial=sqrt(max(1.0-elevation*elevation,0.0));
        let hemisphere=tangent*(cos(angle)*radial)+bitangent*(sin(angle)*radial)+normal*elevation;
        let expected=position+hemisphere*radius*mix(0.15,1.0,progress*progress);
        let projected=view.projection*vec4<f32>(expected,1.0);
        if(projected.w<=0.0) { continue; }
        let uv=projected.xy/projected.w*vec2<f32>(0.5,-0.5)+0.5;
        if(any(uv<vec2<f32>(0.0)) || any(uv>vec2<f32>(1.0))) { continue; }
        let sampleDepth=depthAt(uv); if(sampleDepth>=1.0) { continue; }
        let actual=worldOf(uv,sampleDepth); let range=1.0-smoothstep(radius*0.5,radius,distance(actual,position));
        if(distance(actual,view.camera.xyz)+view.tuning.y<distance(expected,view.camera.xyz)) { occluded+=range; }
        valid+=1.0;
    }
    return pow(clamp(1.0-occluded/max(valid,1.0)*view.tuning.z,0.0,1.0),view.tuning.w);
}
fn blur(uv:vec2<f32>,axis:vec2<f32>) -> f32 {
    let centerEncoded=textureSampleLevel(normalTexture,imageSampler,uv,0.0);
    if(centerEncoded.a==0.0) { return 1.0; }
    let centerNormal=normalize(centerEncoded.xyz*2.0-1.0); let centerDepth=depthAt(uv);
    let weights=array<f32,5>(0.2270270270,0.1945945946,0.1216216216,0.0540540541,0.0162162162);
    var sum=textureSampleLevel(aoTexture,imageSampler,uv,0.0).r*weights[0]; var total=weights[0];
    let step=axis/vec2<f32>(textureDimensions(aoTexture));
    for(var tap=1;tap<5;tap++) { for(var side=-1;side<=1;side+=2) {
        let sampleUV=uv+step*f32(tap*side); let encoded=textureSampleLevel(normalTexture,imageSampler,sampleUV,0.0);
        if(encoded.a==0.0) { continue; }
        let normal=normalize(encoded.xyz*2.0-1.0); let depth=depthAt(sampleUV);
        let edge=exp(-abs(depth-centerDepth)*500.0)*pow(max(dot(normal,centerNormal),0.0),8.0);
        let weight=weights[tap]*edge; sum+=textureSampleLevel(aoTexture,imageSampler,sampleUV,0.0).r*weight; total+=weight;
    }}
    return sum/max(total,0.00001);
}
@fragment fn horizontal(v:Vertex) -> @location(0) f32 { return blur(v.uv,vec2<f32>(1.0,0.0)); }
@fragment fn vertical(v:Vertex) -> @location(0) f32 { return blur(v.uv,vec2<f32>(0.0,1.0)); }
@fragment fn apply(v:Vertex) -> @location(0) vec4<f32> {
    let scene=textureSampleLevel(sceneTexture,imageSampler,v.uv,0.0);
    let ambient=textureSampleLevel(ambientTexture,imageSampler,v.uv,0.0).rgb;
    let visibility=textureSampleLevel(aoTexture,imageSampler,v.uv,0.0).r;
    return vec4<f32>(max(scene.rgb-ambient*(1.0-visibility),vec3<f32>(0.0)),scene.a);
}
