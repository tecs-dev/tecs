// Direction-to-face mapping and Lazarov's split-sum fit from the old renderer.
fn environmentCoordinate(direction:vec3<f32>)->vec3<f32> {
    let axis=abs(direction);var face=vec2<f32>(0.0);var layer=0.0;
    if(axis.x>=axis.y && axis.x>=axis.z) {
        if(direction.x>=0.0) {face=vec2<f32>(-direction.z,-direction.y)/max(axis.x,0.000001);layer=0.0;}
        else {face=vec2<f32>(direction.z,-direction.y)/max(axis.x,0.000001);layer=1.0;}
    } else if(axis.y>=axis.z) {
        if(direction.y>=0.0) {face=vec2<f32>(direction.x,direction.z)/max(axis.y,0.000001);layer=2.0;}
        else {face=vec2<f32>(direction.x,-direction.z)/max(axis.y,0.000001);layer=3.0;}
    } else {
        if(direction.z>=0.0) {face=vec2<f32>(direction.x,-direction.y)/max(axis.z,0.000001);layer=4.0;}
        else {face=vec2<f32>(-direction.x,-direction.y)/max(axis.z,0.000001);layer=5.0;}
    }
    return vec3<f32>(face*0.5+0.5,layer);
}
fn environmentSample(direction:vec3<f32>,lod:f32,rotation:f32)->vec3<f32> {
    let d=normalize(direction);let c=cos(rotation);let s=sin(rotation);
    let coordinate=environmentCoordinate(vec3<f32>(c*d.x+s*d.z,d.y,-s*d.x+c*d.z));
    return textureSampleLevel(environmentMap,environmentSampler,coordinate.xy,i32(coordinate.z),lod).rgb;
}
fn environmentSpecular(base:vec3<f32>,normal:vec3<f32>,eye:vec3<f32>,roughness:f32,metallic:f32,occlusion:f32,intensity:f32,rotation:f32)->vec3<f32> {
    if(intensity<=0.0) {return vec3<f32>(0.0);}
    let r=clamp(roughness,0.04,1.0);let nv=max(dot(normal,eye),0.0);
    let coefficients=r*vec4<f32>(-1.0,-0.0275,-0.572,0.022)+vec4<f32>(1.0,0.0425,1.04,-0.04);
    let a004=min(coefficients.x*coefficients.x,exp2(-9.28*nv))*coefficients.x+coefficients.y;
    let brdf=vec2<f32>(-1.04,1.04)*a004+coefficients.zw;
    let radiance=environmentSample(reflect(-eye,normal),r*f32(textureNumLevels(environmentMap)-1u),rotation);
    return radiance*(mix(vec3<f32>(0.04),base,metallic)*brdf.x+brdf.y)*occlusion*intensity;
}
