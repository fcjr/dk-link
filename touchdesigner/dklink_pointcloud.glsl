// DK Link: point cloud in metres from the unpacked depth and the XY table.
// Input 0: unpacked depth (float millimetres, from dklink_unpack16.glsl)
// Input 1: "DK XY Table" (R,G = x ray; B,A = y ray; 16-bit, range -2..2)
// Output: RGB32F, xyz in metres in the depth camera's frame (x right, y down, z forward),
//         alpha 1 where depth is valid, 0 where it is not.
uniform float uRange;   // FrameTextures.xyTableRange, 2.0
out vec4 fragColor;
float unpack16(float high, float low)
{
    return floor(high * 255.0 + 0.5) * 256.0 + floor(low * 255.0 + 0.5);
}
void main()
{
    float z = texture(sTD2DInputs[0], vUV.st).r * 0.001;
    vec4 t = texture(sTD2DInputs[1], vUV.st);
    float rx = unpack16(t.r, t.g) / 65535.0 * 2.0 * uRange - uRange;
    float ry = unpack16(t.a, t.b) / 65535.0 * 2.0 * uRange - uRange;
    float valid = z > 0.0 ? 1.0 : 0.0;
    fragColor = vec4(rx * z, ry * z, z, valid);
}
