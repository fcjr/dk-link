/*=============================================================================
  The depth pass on the GPU.

  The same four stages as openk4a_depth_model.c - unpack the five-to-eight
  packing into tap planes, project three taps per frequency into a phase
  vector and amplitude, the 5x5 neighbourhood filter, and the de-aliasing and
  gates - written as Metal compute kernels, expression for expression, with
  floating-point contraction off so the answer is the CPU pass's to the
  last bit on the fixtures. The model's tables are uploaded once and the
  rotation again whenever the CPU side rebuilds it for the temperature.
=============================================================================*/

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "openk4a.h"

typedef struct
{
    uint32_t width, height, pixels, sub_pixels, binning, tap_groups, groups, raw_size, flags, lut_entries, weight_entries, pad0;
    uint32_t code_bits, header_bytes, tap_stride, pad1;
    float alpha[3];
    float c_m[3];
    float c_md[3];
    float t[2][3];
    float inverse_r[3][3];
    float inverse_i[3][3];
    float r_offset[2];
    float r_scale[2];
    float ab_multiplier, ab_min_freq_threshold, ab_sum_threshold, ab_ratio_threshold;
    float max_conf_sq, reflectivity_min_threshold, radial_min, radial_max;
    float invalid_lut_entry, center_low_ab_threshold, output_scale, weight_scale;
    float ir_scale;
    uint32_t engine_rules, has_mask, pad2;
    float ls_quarter_sq, output_scale_k;
    uint32_t has_ls, pad3;
    float fitted_residual_units;
    uint32_t pad4, pad5, pad6;
} openk4a_metal_params_t;

static const char *const openk4a_metal_source =
    "#include <metal_stdlib>\n"
    "#pragma METAL fp contract(off)\n"
    "using namespace metal;\n"
    "struct Params {\n"
    "    uint width, height, pixels, sub_pixels, binning, tap_groups, groups, raw_size, flags, lut_entries, weight_entries, pad0;\n"
    "    uint code_bits, header_bytes, tap_stride, pad1;\n"
    "    float alpha[3]; float c_m[3]; float c_md[3]; float t[2][3]; float inverse_r[3][3]; float inverse_i[3][3];\n"
    "    float r_offset[2]; float r_scale[2];\n"
    "    float ab_multiplier, ab_min_freq_threshold, ab_sum_threshold, ab_ratio_threshold;\n"
    "    float max_conf_sq, reflectivity_min_threshold, radial_min, radial_max;\n"
    "    float invalid_lut_entry, center_low_ab_threshold, output_scale, weight_scale;\n"
    "    float ir_scale; uint engine_rules, has_mask, pad2;\n"
    "    float ls_quarter_sq, output_scale_k; uint has_ls, pad3;\n"
    "    float fitted_residual_units; uint pad4, pad5, pad6;\n"
    "};\n"
    "\n"
    "// The sensor's saturation code unpacks to a negative zero, which nothing else makes.\n"
    "static bool tap_is_saturated(float v) { return as_type<uint>(v) == 0x80000000u; }\n"
    "\n"
    "// Plane t of the tap set is the frame's own group stream offset by t strides.\n"
    "kernel void unpack(device const uchar *raw [[buffer(0)]], device const float *signedValue [[buffer(1)]],\n"
    "                   device float *tap [[buffer(2)]], constant Params &p [[buffer(3)]], uint2 id [[thread_position_in_grid]])\n"
    "{\n"
    "    uint w = id.x, t = id.y;\n"
    "    if (w >= p.groups || t >= 9) return;\n"
    "    if (p.code_bits == 8) {\n"
    "        // One byte a pixel coding the difference from the pixel above: a\n"
    "        // thread per column walks it down, summing in integers; 0x80 is the\n"
    "        // saturation code, a zero difference flagged as a negative zero.\n"
    "        uint columns = p.width * p.binning;\n"
    "        uint rows = p.sub_pixels / columns;\n"
    "        uint column = w;\n"
    "        if (column >= columns) return;\n"
    "        uint first = p.header_bytes + t * p.tap_stride + column;\n"
    "        int acc = 0;\n"
    "        for (uint r = 0; r < rows; r++) {\n"
    "            uint at = first + r * columns;\n"
    "            uint code = at < p.raw_size ? (uint)raw[at] : 0u;\n"
    "            uint m = code & 0x7Fu, e = (m >> 4) & 7u, f = m & 15u;\n"
    "            int magnitude = e == 0u ? (int)f : (int)((16u + f) << (e - 1u));\n"
    "            acc += (code & 0x80u) != 0u ? -magnitude : magnitude;\n"
    "            tap[t * p.sub_pixels + r * columns + column] = code == 0x80u ? -0.0f : (float)acc;\n"
    "        }\n"
    "        return;\n"
    "    }\n"
    "    uint g = t * p.tap_groups + w;\n"
    "    uint byte = 256u + g * 8u;\n"
    "    uint fields[5];\n"
    "    if (byte + 8u <= p.raw_size) {\n"
    "        uint lows = (uint)(raw[byte + 5] & 0x0F) | ((uint)(raw[byte + 5] >> 4) << 4) |\n"
    "                    ((uint)(raw[byte + 6] & 0x0F) << 8) | ((uint)(raw[byte + 6] >> 4) << 12) |\n"
    "                    ((uint)(raw[byte + 7] & 0x0F) << 16);\n"
    "        for (uint i = 0; i < 5; i++) fields[i] = ((uint)raw[byte + i] << 4) | ((lows >> (4 * i)) & 0x0F);\n"
    "    } else {\n"
    "        for (uint i = 0; i < 5; i++) fields[i] = 0;\n"
    "    }\n"
    "    uint base = w * 5u;\n"
    "    if (base >= p.sub_pixels) return;\n"
    "    uint write = min(5u, p.sub_pixels - base);\n"
    "    for (uint i = 0; i < write; i++) tap[t * p.sub_pixels + base + i] = signedValue[fields[i] & 0x7FFu];\n"
    "}\n"
    "\n"
    "// A 2x2 binned mode: four sub-pixels summed down, quartered.\n"
    "kernel void bin(device const float *tapSub [[buffer(0)]], device float *tap [[buffer(1)]], constant Params &p [[buffer(2)]],\n"
    "                device uchar *sat [[buffer(3)]], uint2 id [[thread_position_in_grid]])\n"
    "{\n"
    "    uint column = id.x, row = id.y;\n"
    "    if (column >= p.width || row >= p.height) return;\n"
    "    uint subWidth = p.width * p.binning;\n"
    "    float quarter = 1.0f / (float)(p.binning * p.binning);\n"
    "    uchar saturated = 0;\n"
    "    for (uint t = 0; t < 9; t++) {\n"
    "        device const float *line = tapSub + t * p.sub_pixels + row * p.binning * subWidth;\n"
    "        float total = 0.0f;\n"
    "        for (uint dy = 0; dy < p.binning; dy++)\n"
    "            for (uint dx = 0; dx < p.binning; dx++) {\n"
    "                float sub = line[dy * subWidth + column * p.binning + dx];\n"
    "                if (tap_is_saturated(sub)) saturated = 1;\n"
    "                total += sub;\n"
    "            }\n"
    "        tap[t * p.pixels + row * p.width + column] = total * quarter;\n"
    "    }\n"
    "    sat[row * p.width + column] = saturated;\n"
    "}\n"
    "\n"
    "// Per frequency: the three taps through the inverse phase matrix, the\n"
    "// rotation, the unit vector and the amplitude; and the IR as the sum.\n"
    "kernel void project(device const float *tap [[buffer(0)]], device const float *rotate [[buffer(1)]],\n"
    "                    device float *proj [[buffer(2)]], device ushort *ir [[buffer(3)]], constant Params &p [[buffer(4)]],\n"
    "                    device uchar *sat [[buffer(5)]], uint pixel [[thread_position_in_grid]])\n"
    "{\n"
    "    if (pixel >= p.pixels) return;\n"
    "    float amp = 0.0f;\n"
    "    uchar saturated = 0;\n"
    "    for (uint f = 0; f < 3; f++) {\n"
    "        float a = tap[(f * 3 + 0) * p.pixels + pixel];\n"
    "        float b = tap[(f * 3 + 1) * p.pixels + pixel];\n"
    "        float c = tap[(f * 3 + 2) * p.pixels + pixel];\n"
    "        if (tap_is_saturated(a) || tap_is_saturated(b) || tap_is_saturated(c)) saturated = 1;\n"
    "        float real = p.inverse_r[f][0] * a + p.inverse_r[f][1] * b + p.inverse_r[f][2] * c;\n"
    "        float imaginary = p.inverse_i[f][0] * a + p.inverse_i[f][1] * b + p.inverse_i[f][2] * c;\n"
    "        float cosine = rotate[(f * p.pixels + pixel) * 2];\n"
    "        float sine = rotate[(f * p.pixels + pixel) * 2 + 1];\n"
    "        float x = real * cosine - imaginary * sine;\n"
    "        float y = real * sine + imaginary * cosine;\n"
    "        float magnitude = sqrt(x * x + y * y);\n"
    "        float inverse = magnitude > 0.0f ? 1.0f / magnitude : 0.0f;\n"
    "        proj[(f * 3 + 0) * p.pixels + pixel] = x * inverse;\n"
    "        proj[(f * 3 + 1) * p.pixels + pixel] = y * inverse;\n"
    "        proj[(f * 3 + 2) * p.pixels + pixel] = magnitude;\n"
    "        float squared = a * a + b * b + c * c - a * b - a * c - b * c;\n"
    "        if (squared < 0.0f) squared = 0.0f;\n"
    "        amp += (2.0f / 3.0f) * sqrt(squared);\n"
    "    }\n"
    "    if (p.binning == 1) sat[pixel] = saturated;\n"
    "    float value = amp * p.ir_scale;\n"
    "    ir[pixel] = value >= 32767.0f ? (ushort)32767 : (ushort)(value + 0.5f);\n"
    "}\n"
    "\n"
    "static float atan2_turns(float y, float x)\n"
    "{\n"
    "    if (x == 0.0f && y == 0.0f) return 0.0f;\n"
    "    float ax = fabs(x), ay = fabs(y);\n"
    "    float larger = ax > ay ? ax : ay;\n"
    "    float smaller = ax > ay ? ay : ax;\n"
    "    float ratio = smaller / larger;\n"
    "    float ratio2 = ratio * ratio;\n"
    "    float angle = -0.01172120f;\n"
    "    angle = angle * ratio2 + 0.05265332f;\n"
    "    angle = angle * ratio2 + (-0.11643287f);\n"
    "    angle = angle * ratio2 + 0.19354346f;\n"
    "    angle = angle * ratio2 + (-0.33262347f);\n"
    "    angle = angle * ratio2 + 0.99997726f;\n"
    "    angle *= ratio;\n"
    "    angle *= 0.15915494309189533577f;\n"
    "    if (ay > ax) angle = 0.25f - angle;\n"
    "    if (x < 0.0f) angle = 0.5f - angle;\n"
    "    if (y < 0.0f) angle = -angle;\n"
    "    float turns = angle;\n"
    "    if (turns < 0.0f) turns += 1.0f;\n"
    "    return turns;\n"
    "}\n"
    "\n"
    "static float round_half_even(float value)\n"
    "{\n"
    "    float floor_value = floor(value);\n"
    "    float fraction = value - floor_value;\n"
    "    if (fraction > 0.5f) return floor_value + 1.0f;\n"
    "    if (fraction < 0.5f) return floor_value;\n"
    "    return fmod(floor_value, 2.0f) == 0.0f ? floor_value : floor_value + 1.0f;\n"
    "}\n"
    "\n"
    "kernel void filter(device const float *proj [[buffer(0)]], device const float *weights [[buffer(1)]],\n"
    "                   device const float *lut [[buffer(2)]], device const ushort *radialToZ [[buffer(3)]],\n"
    "                   device ushort *depth [[buffer(4)]], constant Params &p [[buffer(5)]],\n"
    "                   device const uchar *mask [[buffer(6)]], device const uchar *sat [[buffer(7)]],\n"
    "                   device const float *lsHalfDot [[buffer(8)]], uint2 id [[thread_position_in_grid]])\n"
    "{\n"
    "    int column = (int)id.x, row = (int)id.y;\n"
    "    int width = (int)p.width, height = (int)p.height;\n"
    "    if (column >= width || row >= height) return;\n"
    "    uint pixel = (uint)row * p.width + (uint)column;\n"
    "    if (p.engine_rules != 0 && (sat[pixel] != 0 || (p.has_mask != 0 && mask[pixel] == 0))) { depth[pixel] = 0; return; }\n"
    "    int first_row = row > 2 ? row - 2 : 0, last_row = row + 2 < height ? row + 2 : height - 1;\n"
    "    int first_column = column > 2 ? column - 2 : 0, last_column = column + 2 < width ? column + 2 : width - 1;\n"
    "    float phase[3], amplitude[3];\n"
    "    for (uint f = 0; f < 3; f++) {\n"
    "        device const float *plane_x = proj + (f * 3 + 0) * p.pixels;\n"
    "        device const float *plane_y = proj + (f * 3 + 1) * p.pixels;\n"
    "        device const float *plane_m = proj + (f * 3 + 2) * p.pixels;\n"
    "        float magnitude = plane_m[pixel];\n"
    "        float sum_x = 0.0f, sum_y = 0.0f, sum_magnitude = 0.0f, sum_weight = 0.0f;\n"
    "        if (magnitude > 0.0f) {\n"
    "            float cx = plane_x[pixel], cy = plane_y[pixel];\n"
    "            bool dim = magnitude <= p.center_low_ab_threshold;\n"
    "            for (int nb_row = first_row; nb_row <= last_row; nb_row++) {\n"
    "                uint row_base = (uint)nb_row * p.width + (uint)first_column;\n"
    "                for (int nb_column = first_column; nb_column <= last_column; nb_column++) {\n"
    "                    uint other = row_base + (uint)(nb_column - first_column);\n"
    "                    float other_magnitude = plane_m[other];\n"
    "                    if (other_magnitude <= 0.0f) continue;\n"
    "                    float weight;\n"
    "                    if (dim) {\n"
    "                        weight = 1.0f;\n"
    "                    } else {\n"
    "                        float cosine = cx * plane_x[other] + cy * plane_y[other];\n"
    "                        int lookup = (int)((cosine + 1.0f) * p.weight_scale);\n"
    "                        if (lookup < 0) lookup = 0; else if (lookup >= (int)p.weight_entries) lookup = (int)p.weight_entries - 1;\n"
    "                        weight = weights[lookup];\n"
    "                    }\n"
    "                    sum_x += weight * plane_x[other] * other_magnitude;\n"
    "                    sum_y += weight * plane_y[other] * other_magnitude;\n"
    "                    sum_magnitude += weight * other_magnitude;\n"
    "                    sum_weight += weight;\n"
    "                }\n"
    "            }\n"
    "        }\n"
    "        phase[f] = sum_weight > 0.0f ? atan2_turns(sum_y, sum_x) : 0.0f;\n"
    "        amplitude[f] = sum_weight > 0.0f ? sqrt(sum_x * sum_x + sum_y * sum_y) / sum_weight : magnitude;\n"
    "    }\n"
    "    // conclude\n"
    "    float coarse[2];\n"
    "    for (uint k = 0; k < 2; k++) coarse[k] = p.t[k][0] * phase[0] + p.t[k][1] * phase[1] + p.t[k][2] * phase[2];\n"
    "    int index = (int)((round_half_even(coarse[1]) - p.r_offset[1]) * p.r_scale[0] + (round_half_even(coarse[0]) - p.r_offset[0]));\n"
    "    bool valid = index >= 0 && index < (int)p.lut_entries;\n"
    "    float radial = 0.0f;\n"
    "    if (valid) {\n"
    "        device const float *wraps = lut + index * 3;\n"
    "        valid = wraps[0] != p.invalid_lut_entry;\n"
    "        float de_aliased[3];\n"
    "        for (uint k = 0; k < 3; k++) { de_aliased[k] = phase[k] + wraps[k]; radial += p.alpha[k] * de_aliased[k]; }\n"
    "        float along = 0.0f;\n"
    "        for (uint k = 0; k < 3; k++) along += p.c_m[k] * de_aliased[k];\n"
    "        float confidence = 0.0f;\n"
    "        for (uint k = 0; k < 3; k++) { float residual = de_aliased[k] - along * p.c_md[k]; confidence += residual * residual; }\n"
    "        float lowest = amplitude[0], highest = amplitude[0], amplitude_sum = 0.0f;\n"
    "        for (uint k = 0; k < 3; k++) {\n"
    "            if (amplitude[k] < lowest) lowest = amplitude[k];\n"
    "            if (amplitude[k] > highest) highest = amplitude[k];\n"
    "            amplitude_sum += amplitude[k];\n"
    "        }\n"
    "        float spread = highest > 0.0f ? (highest - lowest) / highest : 1.0f;\n"
    "        amplitude_sum *= p.ab_multiplier;\n"
    "        valid = valid && confidence <= p.max_conf_sq && radial >= p.radial_min && radial <= p.radial_max &&\n"
    "                spread <= p.ab_ratio_threshold && lowest > p.ab_min_freq_threshold && amplitude_sum > p.ab_sum_threshold &&\n"
    "                amplitude_sum * radial * radial >= p.reflectivity_min_threshold;\n"
    "    }\n"
    "    if (!valid) { depth[pixel] = 0; return; }\n"
    "    float z = radial;\n"
    "    if (p.has_ls != 0) {\n"
    "        float k = p.output_scale_k;\n"
    "        float pp = radial * k;\n"
    "        float denominator = pp - lsHalfDot[pixel];\n"
    "        if (denominator > 0.0f) z = ((pp * pp - p.ls_quarter_sq) / denominator) / k;\n"
    "    }\n"
    "    z += p.fitted_residual_units;\n"
    "    if ((p.flags & 1u) != 0) z *= (float)radialToZ[pixel] / 65535.0f;\n"
    "    depth[pixel] = (ushort)(z * 65535.0f * p.output_scale + 0.5f);\n"
    "}\n";

@interface OpenK4AMetalDecoder : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLComputePipelineState> unpack;
@property(nonatomic, strong) id<MTLComputePipelineState> bin;
@property(nonatomic, strong) id<MTLComputePipelineState> project;
@property(nonatomic, strong) id<MTLComputePipelineState> filter;
@property(nonatomic, strong) id<MTLBuffer> raw;
@property(nonatomic, strong) id<MTLBuffer> signedTable;
@property(nonatomic, strong) id<MTLBuffer> tapSub;
@property(nonatomic, strong) id<MTLBuffer> tap;
@property(nonatomic, strong) id<MTLBuffer> rotate;
@property(nonatomic, strong) id<MTLBuffer> proj;
@property(nonatomic, strong) id<MTLBuffer> lut;
@property(nonatomic, strong) id<MTLBuffer> weights;
@property(nonatomic, strong) id<MTLBuffer> radialToZ;
@property(nonatomic, strong) id<MTLBuffer> lsHalfDot;
@property(nonatomic, strong) id<MTLBuffer> depth;
@property(nonatomic, strong) id<MTLBuffer> ir;
@property(nonatomic, strong) id<MTLBuffer> sat;
@property(nonatomic, strong) id<MTLBuffer> mask;
@property(nonatomic, strong) id<MTLBuffer> params;
@property(nonatomic, assign) const void *model;
@property(nonatomic, assign) uint32_t rotationGeneration;
@property(nonatomic, assign) size_t pixels;
@end

@implementation OpenK4AMetalDecoder

- (instancetype)init
{
    self = [super init];
    if (self == nil)
    {
        return nil;
    }
    @autoreleasepool
    {
        _device = MTLCreateSystemDefaultDevice();
        if (_device == nil)
        {
            _device = MTLCopyAllDevices().firstObject;
        }
        if (_device == nil)
        {
            return nil;
        }
        NSError *error = nil;
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.fastMathEnabled = NO;
        id<MTLLibrary> library = [_device newLibraryWithSource:[NSString stringWithUTF8String:openk4a_metal_source]
                                                       options:options
                                                         error:&error];
        if (library == nil)
        {
            openk4a_log(OPENK4A_LOG_WARNING, "the Metal depth decoder would not compile: %s; using the CPU pass",
                    error.localizedDescription.UTF8String);
            return nil;
        }
        NSArray<NSString *> *names = @[ @"unpack", @"bin", @"project", @"filter" ];
        NSMutableArray *pipelines = [NSMutableArray array];
        for (NSString *name in names)
        {
            id<MTLFunction> function = [library newFunctionWithName:name];
            id<MTLComputePipelineState> pipeline = function != nil ? [_device newComputePipelineStateWithFunction:function error:&error] : nil;
            if (pipeline == nil)
            {
                openk4a_log(OPENK4A_LOG_WARNING, "the Metal kernel %s would not build: %s; using the CPU pass", name.UTF8String,
                        error.localizedDescription.UTF8String);
                return nil;
            }
            [pipelines addObject:pipeline];
        }
        _unpack = pipelines[0];
        _bin = pipelines[1];
        _project = pipelines[2];
        _filter = pipelines[3];
        _queue = [_device newCommandQueue];
        if (_queue == nil)
        {
            return nil;
        }
        float table[2048 + 256];
        for (uint32_t field = 0; field < 2048; field++)
        {
            table[field] = openk4a_depth_signed_value(field);
        }
        for (uint32_t code = 0; code < 256; code++)
        {
            table[2048 + code] = openk4a_depth_signed_value8(code);
        }
        _signedTable = [_device newBufferWithBytes:table length:sizeof(table) options:MTLResourceStorageModeShared];
        _params = [_device newBufferWithLength:sizeof(openk4a_metal_params_t) options:MTLResourceStorageModeShared];
        openk4a_log(OPENK4A_LOG_INFO, "Metal depth decoder on %s", _device.name.UTF8String);
    }
    return self;
}

static id<MTLBuffer> buffer_of(OpenK4AMetalDecoder *self, id<MTLBuffer> existing, size_t length)
{
    if (existing != nil && existing.length >= length)
    {
        return existing;
    }
    return [self.device newBufferWithLength:length options:MTLResourceStorageModeShared];
}

/* The per-model buffers: made when the model changes, the rotation again when
 * the CPU side rebuilds it. */
- (bool)prepareFor:(const openk4a_depth_model_tables_t *)tables model:(const void *)model
{
    const size_t pixels = tables->pixels;
    const size_t subPixels = tables->sub_pixels;
    if (_model != model || _pixels != pixels)
    {
        _tapSub = buffer_of(self, nil, subPixels * 9 * sizeof(float));
        _tap = tables->binning == 1 ? _tapSub : buffer_of(self, nil, pixels * 9 * sizeof(float));
        _proj = buffer_of(self, nil, pixels * 9 * sizeof(float));
        _depth = buffer_of(self, nil, pixels * sizeof(uint16_t));
        _ir = buffer_of(self, nil, pixels * sizeof(uint16_t));
        _sat = buffer_of(self, nil, pixels);
        _mask = tables->mask != NULL ? [_device newBufferWithBytes:tables->mask length:pixels options:MTLResourceStorageModeShared] : nil;
        _rotate = buffer_of(self, nil, pixels * 3 * 2 * sizeof(float));
        _lut = [_device newBufferWithBytes:tables->lut length:(size_t)tables->lut_entries * 3 * sizeof(float) options:MTLResourceStorageModeShared];
        _weights = [_device newBufferWithBytes:tables->weight_table length:(size_t)tables->weight_entries * sizeof(float) options:MTLResourceStorageModeShared];
        _radialToZ = [_device newBufferWithBytes:tables->radial_to_z length:pixels * sizeof(uint16_t) options:MTLResourceStorageModeShared];
        _lsHalfDot = tables->ls_half_dot != NULL
                         ? [_device newBufferWithBytes:tables->ls_half_dot length:pixels * sizeof(float) options:MTLResourceStorageModeShared]
                         : nil;
        if (_tapSub == nil || _tap == nil || _proj == nil || _depth == nil || _ir == nil || _sat == nil || _rotate == nil || _lut == nil ||
            _weights == nil || _radialToZ == nil || (tables->mask != NULL && _mask == nil))
        {
            _model = NULL;
            return false;
        }
        _model = model;
        _pixels = pixels;
        _rotationGeneration = tables->rotation_generation - 1; /* force an upload */
    }
    if (_rotationGeneration != tables->rotation_generation)
    {
        memcpy(_rotate.contents, tables->rotate, pixels * 3 * 2 * sizeof(float));
        _rotationGeneration = tables->rotation_generation;
    }
    return true;
}

- (bool)decode:(openk4a_depth_model_t *)model raw:(const uint8_t *)raw size:(size_t)size depth:(uint16_t *)depth ir:(uint16_t *)ir
{
    openk4a_depth_model_prepare(model, raw, size);
    openk4a_depth_model_tables_t tables;
    if (!openk4a_depth_model_tables(model, &tables))
    {
        return false;
    }
    @autoreleasepool
    {
        if (![self prepareFor:&tables model:model])
        {
            return false;
        }
        _raw = buffer_of(self, _raw, size);
        if (_raw == nil)
        {
            return false;
        }
        memcpy(_raw.contents, raw, size);

        openk4a_metal_params_t *p = (openk4a_metal_params_t *)_params.contents;
        memset(p, 0, sizeof(*p));
        p->width = (uint32_t)tables.width;
        p->height = (uint32_t)tables.height;
        p->pixels = (uint32_t)tables.pixels;
        p->sub_pixels = (uint32_t)tables.sub_pixels;
        p->binning = (uint32_t)tables.binning;
        p->tap_groups = (uint32_t)tables.tap_groups;
        p->groups = (uint32_t)tables.groups;
        p->raw_size = (uint32_t)size;
        p->flags = tables.flags;
        p->lut_entries = (uint32_t)tables.lut_entries;
        p->weight_entries = (uint32_t)tables.weight_entries;
        p->code_bits = (uint32_t)tables.code_bits;
        p->header_bytes = (uint32_t)tables.header_bytes;
        p->tap_stride = (uint32_t)tables.tap_stride;
        memcpy(p->alpha, tables.alpha, sizeof(p->alpha));
        memcpy(p->c_m, tables.c_m, sizeof(p->c_m));
        memcpy(p->c_md, tables.c_md, sizeof(p->c_md));
        memcpy(p->t, tables.t, sizeof(p->t));
        memcpy(p->inverse_r, tables.inverse_r, sizeof(p->inverse_r));
        memcpy(p->inverse_i, tables.inverse_i, sizeof(p->inverse_i));
        memcpy(p->r_offset, tables.r_offset, sizeof(p->r_offset));
        memcpy(p->r_scale, tables.r_scale, sizeof(p->r_scale));
        p->ab_multiplier = tables.ab_multiplier;
        p->ab_min_freq_threshold = tables.ab_min_freq_threshold;
        p->ab_sum_threshold = tables.ab_sum_threshold;
        p->ab_ratio_threshold = tables.ab_ratio_threshold;
        p->max_conf_sq = tables.max_conf_sq;
        p->reflectivity_min_threshold = tables.reflectivity_min_threshold;
        p->radial_min = tables.radial_min;
        p->radial_max = tables.radial_max;
        p->invalid_lut_entry = tables.invalid_lut_entry;
        p->center_low_ab_threshold = tables.center_low_ab_threshold;
        p->output_scale = tables.output_scale;
        p->weight_scale = tables.weight_scale;
        p->ir_scale = tables.ir_scale;
        p->engine_rules = tables.engine_rules ? 1u : 0u;
        p->has_mask = tables.mask != NULL ? 1u : 0u;
        p->has_ls = tables.ls_half_dot != NULL && _lsHalfDot != nil ? 1u : 0u;
        p->ls_quarter_sq = tables.ls_quarter_sq;
        p->output_scale_k = 65535.0f * tables.output_scale;
        p->fitted_residual_units = tables.fitted_residual_units;

        id<MTLCommandBuffer> command = [_queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (command == nil || encoder == nil)
        {
            return false;
        }

        [encoder setComputePipelineState:_unpack];
        [encoder setBuffer:_raw offset:0 atIndex:0];
        [encoder setBuffer:_signedTable offset:0 atIndex:1];
        [encoder setBuffer:_tapSub offset:0 atIndex:2];
        [encoder setBuffer:_params offset:0 atIndex:3];
        {
            const NSUInteger threads = tables.code_bits == 8 ? (NSUInteger)tables.width * (NSUInteger)tables.binning
                                                             : (NSUInteger)tables.groups;
            [encoder dispatchThreads:MTLSizeMake(threads, 9, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        }

        if (tables.binning != 1)
        {
            [encoder setComputePipelineState:_bin];
            [encoder setBuffer:_tapSub offset:0 atIndex:0];
            [encoder setBuffer:_tap offset:0 atIndex:1];
            [encoder setBuffer:_params offset:0 atIndex:2];
            [encoder setBuffer:_sat offset:0 atIndex:3];
            [encoder dispatchThreads:MTLSizeMake((NSUInteger)tables.width, (NSUInteger)tables.height, 1)
                threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
        }

        [encoder setComputePipelineState:_project];
        [encoder setBuffer:_tap offset:0 atIndex:0];
        [encoder setBuffer:_rotate offset:0 atIndex:1];
        [encoder setBuffer:_proj offset:0 atIndex:2];
        [encoder setBuffer:_ir offset:0 atIndex:3];
        [encoder setBuffer:_params offset:0 atIndex:4];
        [encoder setBuffer:_sat offset:0 atIndex:5];
        [encoder dispatchThreads:MTLSizeMake(tables.pixels, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];

        if (depth != NULL)
        {
            [encoder setComputePipelineState:_filter];
            [encoder setBuffer:_proj offset:0 atIndex:0];
            [encoder setBuffer:_weights offset:0 atIndex:1];
            [encoder setBuffer:_lut offset:0 atIndex:2];
            [encoder setBuffer:_radialToZ offset:0 atIndex:3];
            [encoder setBuffer:_depth offset:0 atIndex:4];
            [encoder setBuffer:_params offset:0 atIndex:5];
            [encoder setBuffer:(_mask != nil ? _mask : _sat) offset:0 atIndex:6];
            [encoder setBuffer:_sat offset:0 atIndex:7];
            [encoder setBuffer:(_lsHalfDot != nil ? _lsHalfDot : _proj) offset:0 atIndex:8];
            [encoder dispatchThreads:MTLSizeMake((NSUInteger)tables.width, (NSUInteger)tables.height, 1)
                threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
        }
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
        {
            openk4a_log(OPENK4A_LOG_WARNING, "the Metal depth pass failed: %s", command.error.localizedDescription.UTF8String);
            return false;
        }
        if (depth != NULL)
        {
            memcpy(depth, _depth.contents, tables.pixels * sizeof(uint16_t));
        }
        if (ir != NULL)
        {
            memcpy(ir, _ir.contents, tables.pixels * sizeof(uint16_t));
        }
    }
    return true;
}

@end

void *openk4a_metal_decoder_create(void)
{
    @autoreleasepool
    {
        OpenK4AMetalDecoder *decoder = [[OpenK4AMetalDecoder alloc] init];
        return decoder != nil ? (void *)CFBridgingRetain(decoder) : NULL;
    }
}

void openk4a_metal_decoder_destroy(void *decoder)
{
    if (decoder != NULL)
    {
        CFBridgingRelease(decoder);
    }
}

bool openk4a_metal_decode(void *decoder, openk4a_depth_model_t *model, const uint8_t *raw, size_t size, uint16_t *depth, uint16_t *ir)
{
    if (decoder == NULL || model == NULL || raw == NULL)
    {
        return false;
    }
    OpenK4AMetalDecoder *self = (__bridge OpenK4AMetalDecoder *)decoder;
    return [self decode:model raw:raw size:size depth:depth ir:ir];
}
