// Ordered mark, scan and compact for indexed indirect mesh draws.
struct MeshInstance { translation: vec4<f32>, rotation: vec4<f32>, scale: vec4<f32>, tint: vec4<f32>, bounds: vec4<f32>, palette: vec4<u32>, }
struct MeshInfo { geometry: vec4<u32>, counts: vec4<u32>, }
struct MeshView { projection: mat4x4<f32>, camera: vec4<f32>, }
@group(0) @binding(1) var<storage, read> instances: array<MeshInstance>;
@group(0) @binding(3) var<storage, read_write> visible: array<u32>;
@group(0) @binding(4) var<storage, read_write> scan: array<u32>;
@group(0) @binding(5) var<storage, read_write> args: array<u32>;
@group(0) @binding(6) var<uniform> mesh: MeshInfo;
@group(0) @binding(7) var<uniform> view: MeshView;
var<workgroup> prefix: array<u32, 256>;
fn rotate(q: vec4<f32>, p: vec3<f32>) -> vec3<f32> { return p + 2.0 * cross(q.xyz, cross(q.xyz, p) + q.w * p); }
fn survives(index: u32) -> bool {
    let value = instances[index]; let q = normalize(value.rotation);
    let center = rotate(q, value.bounds.xyz * value.scale.xyz) + value.translation.xyz;
    let radius = value.bounds.w * max(max(abs(value.scale.x), abs(value.scale.y)), abs(value.scale.z));
    let m = transpose(view.projection);
    let planes = array<vec4<f32>, 6>(m[3]+m[0], m[3]-m[0], m[3]+m[1], m[3]-m[1], m[2], m[3]-m[2]);
    for (var i=0u; i<6u; i++) { if (dot(planes[i], vec4<f32>(center,1.0)) < -radius * length(planes[i].xyz)) { return false; } }
    return true;
}
@compute @workgroup_size(256) fn mark(@builtin(global_invocation_id) global: vec3<u32>, @builtin(local_invocation_index) lane: u32, @builtin(workgroup_id) group: vec3<u32>) {
    var flag = 0u; if (global.x < mesh.counts.z && survives(global.x)) { flag = 1u; }
    prefix[lane] = flag; workgroupBarrier();
    for (var offset=1u; offset<256u; offset*=2u) {
        var add = 0u; if (lane>=offset) { add=prefix[lane-offset]; } workgroupBarrier();
        prefix[lane]+=add; workgroupBarrier();
    }
    if (global.x<mesh.counts.z) { scan[global.x]=prefix[lane]-flag; visible[global.x]=flag; }
    if (lane==255u) { scan[mesh.counts.z+group.x]=prefix[lane]; }
}
@compute @workgroup_size(1) fn scanBlocks() {
    var total=0u;
    for(var block=0u;block<mesh.counts.w;block++) { let at=mesh.counts.z+block; let count=scan[at]; scan[at]=total; total+=count; }
    args[0]=mesh.counts.y; args[1]=total; args[2]=0u; args[3]=0u; args[4]=0u;
}
@compute @workgroup_size(256) fn compact(@builtin(global_invocation_id) global: vec3<u32>) {
    let index=global.x;
    // The second half holds the ordered result, preserving marks until all reads end.
    if (index<mesh.counts.z && visible[index]!=0u) { visible[mesh.counts.z + scan[mesh.counts.z+index/256u] + scan[index]]=index; }
}

// Imported scenes commonly have one instance per geometry chunk. They need
// the same GPU frustum test but no parallel prefix sum or intermediate scan.
@compute @workgroup_size(1) fn single() {
    visible[1] = 0u;
    args[0] = mesh.counts.y;
    args[1] = select(0u, 1u, survives(0u));
    args[2] = 0u; args[3] = 0u; args[4] = 0u;
}
