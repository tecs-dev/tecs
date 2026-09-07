// The old mesh vertex streams, morph-before-skin order and material equations.
struct MeshInstance {
    translation: vec4<f32>, rotation: vec4<f32>, scale: vec4<f32>, tint: vec4<f32>,
    bounds: vec4<f32>, palette: vec4<u32>,
}
struct MeshInfo { geometry: vec4<u32>, counts: vec4<u32>, }
struct MeshView { projection: mat4x4<f32>, camera: vec4<f32>, }
struct Material { base: vec4<f32>, emissionModel: vec4<f32>, factors: vec4<f32>, alpha: vec4<f32>, }
@group(0) @binding(0) var<storage, read> vertices: array<f32>;
@group(0) @binding(1) var<storage, read> instances: array<MeshInstance>;
@group(0) @binding(2) var<storage, read> palettes: array<f32>;
@group(0) @binding(3) var<storage, read> visible: array<u32>;
@group(0) @binding(6) var<uniform> mesh: MeshInfo;
@group(0) @binding(7) var<uniform> view: MeshView;
struct MeshLighting { direction: vec4<f32>, colorAmbient: vec4<f32>, fog: vec4<f32>, ranges: vec4<f32>, probe: array<vec4<f32>, 6>, }
@group(0) @binding(8) var<uniform> lighting: MeshLighting;
struct LocalLight { positionRadius: vec4<f32>, colorIntensity: vec4<f32>, directionOuter: vec4<f32>, coneType: vec4<f32>, }
@group(0) @binding(9) var<storage,read> localLights: array<LocalLight>;
@group(0) @binding(10) var<storage,read> lightTiles: array<u32>;
@group(0) @binding(11) var<uniform> lightInfo: vec4<u32>;
struct Environment {inverse:mat4x4<f32>,camera:vec4<f32>,tuning:vec4<f32>,size:vec4<f32>,}
@group(0) @binding(12) var environmentMap:texture_2d_array<f32>;
@group(0) @binding(13) var environmentSampler:sampler;
@group(0) @binding(14) var<uniform> environment:Environment;
@group(1) @binding(0) var mapSampler: sampler;
@group(1) @binding(1) var baseMap: texture_2d<f32>;
@group(1) @binding(2) var normalMap: texture_2d<f32>;
@group(1) @binding(3) var mrMap: texture_2d<f32>;
@group(1) @binding(4) var occlusionMap: texture_2d<f32>;
@group(1) @binding(5) var emissionMap: texture_2d<f32>;
@group(1) @binding(6) var<uniform> material: Material;
struct ShadowInfo { matrices: array<mat4x4<f32>,3>, splits: vec4<f32>, cameraDepth: vec4<f32>, tuning: vec4<f32>, }
@group(2) @binding(0) var shadowMap: texture_depth_2d_array;
@group(2) @binding(1) var shadowSampler: sampler_comparison;
@group(2) @binding(2) var<uniform> shadows: ShadowInfo;
fn shadowAt(world:vec3<f32>,cascade:u32) -> f32 {
    let p=shadows.matrices[cascade]*vec4<f32>(world,1.0);
    let uv=p.xy/p.w*vec2<f32>(0.5,-0.5)+0.5;
    let depth=p.z/p.w-shadows.tuning.x;
    if(any(uv<vec2<f32>(0.0)) || any(uv>vec2<f32>(1.0)) || depth<0.0 || depth>1.0) { return 1.0; }
    let texel=shadows.tuning.y/vec2<f32>(textureDimensions(shadowMap));
    var visibility=0.0;
    for(var y=-1;y<=1;y++) { for(var x=-1;x<=1;x++) {
        visibility+=textureSampleCompareLevel(shadowMap,shadowSampler,uv+vec2<f32>(f32(x),f32(y))*texel,i32(cascade),depth);
    }}
    return visibility/9.0;
}
fn directionalShadow(world:vec3<f32>) -> f32 {
    if(shadows.tuning.w==0.0) { return 1.0; }
    let depth=dot(shadows.cameraDepth,vec4<f32>(world,1.0));
    if(depth>shadows.splits.z) { return 1.0; }
    let cascade=select(select(0u,1u,depth>shadows.splits.x),2u,depth>shadows.splits.y);
    var visibility=shadowAt(world,cascade);
    let previous=select(0.0,shadows.splits[max(cascade,1u)-1u],cascade>0u);
    let fade=(shadows.splits[cascade]-previous)*shadows.splits.w;
    if(fade>0.0 && depth>shadows.splits[cascade]-fade) {
        var next=1.0;
        if(cascade<2u) { next=shadowAt(world,cascade+1u); }
        visibility=mix(visibility,next,clamp((depth-(shadows.splits[cascade]-fade))/fade,0.0,1.0));
    }
    return mix(1.0,visibility,shadows.tuning.z);
}
@group(3) @binding(0) var localShadowMap:texture_depth_2d_array;
@group(3) @binding(1) var localShadowSampler:sampler_comparison;
@group(3) @binding(2) var<storage,read> localShadowMatrices:array<mat4x4<f32>>;
@group(3) @binding(3) var<uniform> localShadowTuning:vec4<f32>;
fn localShadow(light:LocalLight,world:vec3<f32>) -> f32 {
    if(light.coneType.w==0.0) {return 1.0;}
    var face=0u;
    if(light.coneType.y==0.0) {
        let delta=world-light.positionRadius.xyz;let absolute=abs(delta);
        if(absolute.x>=absolute.y && absolute.x>=absolute.z) {face=select(1u,0u,delta.x>=0.0);}
        else if(absolute.y>=absolute.z) {face=select(3u,2u,delta.y>=0.0);}
        else {face=select(5u,4u,delta.z>=0.0);}
    }
    let index=u32(light.coneType.w)-1u+face;
    let p=localShadowMatrices[index]*vec4<f32>(world,1.0);
    if(p.w<=0.0) {return 1.0;}
    let uv=p.xy/p.w*vec2<f32>(0.5,-0.5)+0.5;let depth=p.z/p.w-localShadowTuning.x;
    if(any(uv<vec2<f32>(0.0)) || any(uv>vec2<f32>(1.0)) || depth<0.0 || depth>1.0) {return 1.0;}
    let texel=localShadowTuning.y/vec2<f32>(textureDimensions(localShadowMap));var visibility=0.0;
    for(var y=-1;y<=1;y++) {for(var x=-1;x<=1;x++) {visibility+=textureSampleCompareLevel(localShadowMap,localShadowSampler,uv+vec2<f32>(f32(x),f32(y))*texel,i32(index),depth);}}
    return visibility/9.0;
}
fn rotate(q: vec4<f32>, p: vec3<f32>) -> vec3<f32> { return p + 2.0 * cross(q.xyz, cross(q.xyz, p) + q.w * p); }
fn v3(at: u32) -> vec3<f32> { return vec3<f32>(vertices[at], vertices[at+1], vertices[at+2]); }
fn joint(at: u32) -> mat4x4<f32> {
    return mat4x4<f32>(vec4<f32>(palettes[at], palettes[at+1], palettes[at+2], palettes[at+3]), vec4<f32>(palettes[at+4], palettes[at+5], palettes[at+6], palettes[at+7]), vec4<f32>(palettes[at+8], palettes[at+9], palettes[at+10], palettes[at+11]), vec4<f32>(palettes[at+12], palettes[at+13], palettes[at+14], palettes[at+15]));
}
struct VertexOut {
    @builtin(position) position: vec4<f32>, @location(0) world: vec3<f32>,
    @location(1) normal: vec3<f32>, @location(2) tangent: vec4<f32>, @location(3) uv: vec2<f32>, @location(4) tint: vec4<f32>, @location(7) @interpolate(flat) opacity:f32,
}
@vertex fn vertexMain(@builtin(vertex_index) vertex: u32, @builtin(instance_index) index: u32) -> VertexOut {
    let instance = instances[visible[mesh.counts.z + index]];
    let at = vertex * 12u;
    var position = v3(at); var normal = v3(at+3u); var tangent = vec4<f32>(v3(at+6u), vertices[at+9u]);
    for (var morphIndex = 0u; morphIndex < min(mesh.counts.x, instance.palette.w); morphIndex++) {
        let weight = palettes[instance.palette.z + morphIndex];
        let offset = mesh.geometry.w + (morphIndex * mesh.geometry.x + vertex) * 9u;
        position += v3(offset) * weight; normal += v3(offset+3u) * weight;
        tangent = vec4<f32>(tangent.xyz + v3(offset+6u) * weight, tangent.w);
    }
    if (mesh.geometry.z != 0u && instance.palette.y != 0u) {
        let skin = mesh.geometry.z + vertex * 8u;
        var matrix = mat4x4<f32>();
        for (var lane = 0u; lane < 4u; lane++) {
            let weight = vertices[skin+4u+lane];
            if (weight > 0.0) { matrix += joint(instance.palette.x + u32(vertices[skin+lane]) * 16u) * weight; }
        }
        position = (matrix * vec4<f32>(position, 1.0)).xyz;
        normal = (matrix * vec4<f32>(normal, 0.0)).xyz;
        tangent = vec4<f32>((matrix * vec4<f32>(tangent.xyz, 0.0)).xyz, tangent.w);
    }
    let q = normalize(instance.rotation);
    let world = rotate(q, position * instance.scale.xyz) + instance.translation.xyz;
    var output: VertexOut;
    output.position = view.projection * vec4<f32>(world, 1.0); output.world = world;
    output.normal = normalize(rotate(q, normal / instance.scale.xyz));
    output.tangent = vec4<f32>(normalize(rotate(q, tangent.xyz * instance.scale.xyz)), tangent.w * sign(instance.scale.x * instance.scale.y * instance.scale.z));
    output.uv = vec2<f32>(vertices[at+10u], vertices[at+11u]);
    output.opacity = instance.tint.a;
    output.tint = instance.tint;
    if (mesh.geometry.y != 0u) { let color = mesh.geometry.y + vertex * 4u; output.tint *= vec4<f32>(v3(color), vertices[color+3u]); }
    return output;
}
fn brdf(base: vec3<f32>, roughness: f32, metallic: f32, normal: vec3<f32>, eye: vec3<f32>, light: vec3<f32>) -> vec3<f32> {
    let halfway = normalize(eye + light);
    let ndl = max(dot(normal, light), 0.0); let ndv = max(dot(normal, eye), 0.001);
    let ndh = max(dot(normal, halfway), 0.0); let vdh = max(dot(eye, halfway), 0.0);
    let alpha = max(roughness * roughness, 0.002); let a2 = alpha * alpha;
    let denominator = ndh * ndh * (a2 - 1.0) + 1.0;
    let distribution = a2 / (3.14159265 * denominator * denominator);
    let k = (roughness + 1.0) * (roughness + 1.0) / 8.0;
    let geometry = ndl / (ndl * (1.0-k) + k) * ndv / (ndv * (1.0-k) + k);
    let f0 = mix(vec3<f32>(0.04), base, metallic);
    let fresnel = f0 + (1.0-f0) * pow(1.0-vdh, 5.0);
    return ((1.0-fresnel) * (1.0-metallic) * base / 3.14159265 + distribution * geometry * fresnel / max(4.0 * ndv * ndl, 0.001)) * ndl;
}
struct Surface { @location(0) color:vec4<f32>, @location(1) ambient:vec4<f32>, @location(2) normal:vec4<f32>, }
fn shade(input: VertexOut, front: bool) -> Surface {
    let base = textureSample(baseMap, mapSampler, input.uv) * material.base * input.tint;
    if (material.alpha.x == 1.0 && base.a < material.alpha.y) { discard; }
    var normal = normalize(input.normal);
    if (!front && material.alpha.z != 0.0) { normal = -normal; }
    let tangent = normalize(input.tangent.xyz);
    var mapped = textureSample(normalMap, mapSampler, input.uv).xyz * 2.0 - 1.0;
    mapped = vec3<f32>(mapped.xy * material.factors.z, mapped.z);
    normal = normalize(mat3x3<f32>(tangent, cross(normal, tangent) * input.tangent.w, normal) * mapped);
    let mr = textureSample(mrMap, mapSampler, input.uv);
    let metallic = clamp(mr.b * material.factors.x, 0.0, 1.0);
    let roughness = clamp(mr.g * material.factors.y, 0.04, 1.0);
    let occlusion = mix(1.0, textureSample(occlusionMap, mapSampler, input.uv).r, material.factors.w);
    let emission = textureSample(emissionMap, mapSampler, input.uv).rgb * material.emissionModel.rgb;
    let light = -normalize(lighting.direction.xyz);
    let radiance = lighting.colorAmbient.rgb * lighting.direction.w * directionalShadow(input.world);
    let squared = normal * normal;
    let irradiance = lighting.probe[select(1u,0u,normal.x >= 0.0)].rgb * squared.x
        + lighting.probe[select(3u,2u,normal.y >= 0.0)].rgb * squared.y
        + lighting.probe[select(5u,4u,normal.z >= 0.0)].rgb * squared.z;
    let ambient = vec3<f32>(lighting.colorAmbient.w) + irradiance * lighting.ranges.z;
    var color = base.rgb * ambient * occlusion + brdf(base.rgb, roughness, metallic, normal, normalize(view.camera.xyz-input.world), light) * radiance + emission;
    if (material.emissionModel.w == 1.0) { color = base.rgb + emission; }
    if (material.emissionModel.w == 2.0) { color = base.rgb * (ambient * occlusion + max(dot(normal, light), 0.0) * radiance) + emission; }
    if (material.emissionModel.w != 1.0) {
        let tile = vec2<u32>(input.position.xy)/16u;
        for(var word=0u;word<8u;word++) {
            var bits=lightTiles[(tile.y*lightInfo.w+tile.x)*8u+word];
            while(bits!=0u) {
                let bit=firstTrailingBit(bits); bits &= bits-1u;
                let source=localLights[word*32u+bit];
                let delta=source.positionRadius.xyz-input.world;
                let distanceSquared=max(dot(delta,delta),0.0001);
                let incoming=delta*inverseSqrt(distanceSquared);
                let cutoff=clamp(1.0-pow(sqrt(distanceSquared)/source.positionRadius.w,4.0),0.0,1.0);
                var cone=1.0;
                if(source.coneType.y!=0.0) { cone=smoothstep(source.directionOuter.w,source.coneType.x,dot(-incoming,source.directionOuter.xyz)); }
                let radiance=source.colorIntensity.rgb*source.colorIntensity.w*cutoff*cutoff*cone/distanceSquared*localShadow(source,input.world);
                if(material.emissionModel.w==2.0) { color+=base.rgb*max(dot(normal,incoming),0.0)*radiance; }
                else { color+=brdf(base.rgb,roughness,metallic,normal,normalize(view.camera.xyz-input.world),incoming)*radiance; }
            }
        }
    }
    if(material.emissionModel.w==0.0) {
        color+=environmentSpecular(base.rgb,normal,normalize(view.camera.xyz-input.world),roughness,metallic,occlusion,environment.tuning.x,environment.tuning.z);
    }
    var ambientContribution=select(base.rgb*ambient*occlusion,vec3<f32>(0.0),material.emissionModel.w==1.0);
    if (lighting.fog.w != 0.0) {
        let amount = clamp((distance(view.camera.xyz,input.world)-lighting.ranges.x)/(lighting.ranges.y-lighting.ranges.x),0.0,1.0);
        color = mix(color,lighting.fog.rgb,amount);
        ambientContribution*=1.0-amount;
    }
    let alpha = select(input.opacity, base.a, material.alpha.x == 2.0);
    return Surface(vec4<f32>(color*alpha,alpha),vec4<f32>(ambientContribution*alpha,alpha),vec4<f32>(normal*0.5+0.5,1.0));
}
@fragment fn fragmentMain(input:VertexOut,@builtin(front_facing) front:bool) -> @location(0) vec4<f32> { return shade(input,front).color; }
@fragment fn fragmentGeometry(input:VertexOut,@builtin(front_facing) front:bool) -> Surface { return shade(input,front); }

@fragment fn shadowMain(input:VertexOut) {
    if(material.alpha.x==1.0 && (textureSample(baseMap,mapSampler,input.uv)*material.base*input.tint).a<material.alpha.y) { discard; }
}
