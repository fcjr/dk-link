// Kinect for Mac: unpack a 16-bit plane that was packed into Syphon's 8-bit BGRA.
// Input 0: "Kinect Depth" or "Kinect IR" (R = high byte, G = low byte).
// Output: 32-bit float TOP, value in millimetres (depth) or raw IR counts.
// Set the GLSL TOP's Output Pixel Format to 32-bit float (RGBA) or (R).
out vec4 fragColor;
void main()
{
    vec4 packed = texture(sTD2DInputs[0], vUV.st);
    float value = floor(packed.r * 255.0 + 0.5) * 256.0 + floor(packed.g * 255.0 + 0.5);
    fragColor = vec4(value, value, value, 1.0);
}
