struct Light { positionRadius: vec4<f32>, colorIntensity: vec4<f32>, directionOuter: vec4<f32>, coneType: vec4<f32>, }
struct View { projection: mat4x4<f32>, camera: vec4<f32>, }
@group(0) @binding(0) var<storage,read> lights: array<Light>;
@group(0) @binding(1) var<storage,read_write> tiles: array<u32>;
@group(0) @binding(2) var<uniform> info: vec4<u32>;
@group(0) @binding(3) var<uniform> view: View;
@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let tile = invocation.x;
    if (tile >= info.w * ((info.z + 15u) / 16u)) { return; }
    let xy = vec2<u32>(tile % info.w,tile / info.w);
    let low = vec2<f32>(xy*16u)/vec2<f32>(info.yz)*2.0-1.0;
    let high = vec2<f32>((xy+1u)*16u)/vec2<f32>(info.yz)*2.0-1.0;
    let m = transpose(view.projection);
    let planes = array<vec4<f32>,6>(m[0]-low.x*m[3],high.x*m[3]-m[0],m[1]+high.y*m[3],-low.y*m[3]-m[1],m[2],m[3]-m[2]);
    for (var word=0u;word<8u;word++) {
        var mask=0u;
        for(var bit=0u;bit<32u;bit++) {
            let index=word*32u+bit;
            if(index>=info.x) { break; }
            let sphere=lights[index].positionRadius;
            var visible=true;
            for(var plane=0u;plane<6u;plane++) {
                if(dot(planes[plane],vec4<f32>(sphere.xyz,1.0)) < -sphere.w*length(planes[plane].xyz)) { visible=false; }
            }
            if(visible) { mask|=1u<<bit; }
        }
        tiles[tile*8u+word]=mask;
    }
}
