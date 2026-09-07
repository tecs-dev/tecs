struct Instance {translation:vec4<f32>,rotation:vec4<f32>,scale:vec4<f32>,tint:vec4<f32>,bounds:vec4<f32>,palette:vec4<u32>,}
struct Geometry {geometry:vec4<u32>,counts:vec4<u32>,}
struct Key {depth:f32,entity:u32,instance:u32,valid:u32,}
struct View {projection:mat4x4<f32>,camera:vec4<f32>,}
@group(0) @binding(0) var<storage,read> instances:array<Instance>;
@group(0) @binding(1) var<storage,read> lookups:array<vec4<u32>>;
@group(0) @binding(2) var<storage,read> geometries:array<Geometry>;
@group(0) @binding(3) var<storage,read_write> keys:array<Key>;
@group(0) @binding(4) var<storage,read_write> commands:array<u32>;
@group(0) @binding(5) var<storage,read_write> visible:array<u32>;
@group(0) @binding(6) var<uniform> params:vec4<u32>;
@group(0) @binding(7) var<storage,read_write> total:atomic<u32>;
@group(0) @binding(8) var<uniform> view:View;
fn rotate(q:vec4<f32>,p:vec3<f32>)->vec3<f32> {return p+2.0*cross(q.xyz,cross(q.xyz,p)+q.w*p);}
@compute @workgroup_size(256) fn mark(@builtin(global_invocation_id) invocation:vec3<u32>) {
    let index=invocation.x;if(index>=params.y) {return;}
    if(index>=params.x) {keys[index]=Key(-3.402823e38,0xffffffffu,index,0u);return;}
    let instance=instances[index];let center=rotate(normalize(instance.rotation),instance.bounds.xyz*instance.scale.xyz)+instance.translation.xyz;
    let radius=instance.bounds.w*max(max(abs(instance.scale.x),abs(instance.scale.y)),abs(instance.scale.z));
    let m=transpose(view.projection);let planes=array<vec4<f32>,6>(m[3]+m[0],m[3]-m[0],m[3]+m[1],m[3]-m[1],m[2],m[3]-m[2]);
    var valid=1u;
    for(var plane=0u;plane<6u;plane++) {if(dot(planes[plane],vec4<f32>(center,1.0)) < -radius*length(planes[plane].xyz)) {valid=0u;}}
    let depth=(view.projection*vec4<f32>(center,1.0)).w;
    keys[index]=Key(depth,lookups[index].z,index,valid);
    if(valid!=0u) {atomicAdd(&total,1u);}
}
fn before(a:Key,b:Key)->bool {
    if(a.valid!=b.valid) {return a.valid>b.valid;}
    if(a.depth!=b.depth) {return a.depth>b.depth;}
    return a.entity<b.entity;
}
@compute @workgroup_size(256) fn sort(@builtin(global_invocation_id) invocation:vec3<u32>) {
    let index=invocation.x;if(index>=params.y) {return;}
    let other=index^params.w;if(other<=index || other>=params.y) {return;}
    let a=keys[index];let b=keys[other];let ascending=(index&params.z)==0u;
    if(select(before(a,b),before(b,a),ascending)) {keys[index]=b;keys[other]=a;}
}
@compute @workgroup_size(256) fn emit(@builtin(global_invocation_id) invocation:vec3<u32>) {
    let index=invocation.x;if(index>=params.x) {return;}
    let key=keys[index];visible[index]=select(0u,key.instance,key.valid!=0u);
    if(params.z==1u && index!=0u) {return;}
    let lookup=lookups[visible[index]];let geometry=geometries[lookup.x];let at=index*5u;
    commands[at]=select(0u,geometry.counts.y,key.valid!=0u);
    commands[at+1u]=select(1u,atomicLoad(&total),params.z==1u);
    commands[at+2u]=geometry.counts.z;commands[at+3u]=0u;commands[at+4u]=select(index,0u,params.z==1u);
}
