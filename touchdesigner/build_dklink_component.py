"""Builds the DK Link component inside TouchDesigner and saves it as dklink.tox.

Run it from TouchDesigner's Textport (Dialogs > Textport):

    exec(open('/path/to/dk-link/touchdesigner/build_dklink_component.py').read())

It makes a Base COMP named `dklink` in /project1 with:
    color        Syphon Spout In TOP  "DK Color"
    depth_packed Syphon Spout In TOP  "DK Depth"
    ir_packed    Syphon Spout In TOP  "DK IR"
    xy_packed    Syphon Spout In TOP  "DK XY Table"
    depth_mm     GLSL TOP, 32-bit float, millimetres (0 = no depth)
    ir           GLSL TOP, 32-bit float, IR counts
    pointcloud   GLSL TOP, RGB32F metres, alpha = valid
and outputs: color, depth_mm, ir, pointcloud.

The app must be running (so the servers exist) for the Syphon TOPs to connect,
but the network is built either way.
"""
import os

ROOT = os.path.dirname(os.path.abspath(__file__)) if '__file__' in globals() else None

UNPACK = '''out vec4 fragColor;
void main()
{
    vec4 packed = texture(sTD2DInputs[0], vUV.st);
    float value = floor(packed.r * 255.0 + 0.5) * 256.0 + floor(packed.g * 255.0 + 0.5);
    fragColor = vec4(value, value, value, 1.0);
}
'''

POINTCLOUD = '''uniform float uRange;
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
'''


def set_par(o, names, value):
    """Sets the first parameter of `o` that exists among `names`; TouchDesigner
    versions differ in a few parameter names."""
    for name in names:
        par = getattr(o.par, name, None)
        if par is not None:
            par.val = value
            return True
    print('dklink: no parameter named any of', names, 'on', o.path)
    return False


def syphon_in(comp, name, server, x, y):
    top = comp.create(syphonspoutinTOP, name)
    top.nodeX, top.nodeY = x, y
    set_par(top, ['sendername', 'servername', 'name'], server)
    return top


def glsl(comp, name, source, inputs, x, y, float_format=True):
    dat = comp.create(textDAT, name + '_glsl')
    dat.text = source
    dat.nodeX, dat.nodeY = x, y - 120
    top = comp.create(glslTOP, name)
    top.nodeX, top.nodeY = x, y
    set_par(top, ['pixeldat'], dat.path)
    for i, source_top in enumerate(inputs):
        top.inputConnectors[i].connect(source_top)
    if float_format:
        # 32-bit float RGBA; the enum index differs between versions, so the
        # menu label is matched instead.
        for par_name in ['format']:
            par = getattr(top.par, par_name, None)
            if par is not None:
                for i, label in enumerate(par.menuLabels):
                    if '32' in label and 'RGBA' in label:
                        par.menuIndex = i
                        break
    set_par(top, ['outputresolution'], 'input')
    return top


def build(parent=None):
    parent = parent or op('/project1')
    existing = parent.op('dklink')
    if existing:
        existing.destroy()
    comp = parent.create(baseCOMP, 'dklink')
    comp.nodeX, comp.nodeY = 0, 0

    color = syphon_in(comp, 'color', 'DK Color', 0, 300)
    depth_packed = syphon_in(comp, 'depth_packed', 'DK Depth', 0, 150)
    ir_packed = syphon_in(comp, 'ir_packed', 'DK IR', 0, 0)
    xy_packed = syphon_in(comp, 'xy_packed', 'DK XY Table', 0, -150)

    depth_mm = glsl(comp, 'depth_mm', UNPACK, [depth_packed], 250, 150)
    ir = glsl(comp, 'ir', UNPACK, [ir_packed], 250, 0)
    pointcloud = glsl(comp, 'pointcloud', POINTCLOUD, [depth_mm, xy_packed], 500, 150)
    # the uniform: name + value
    set_par(pointcloud, ['uniname0'], 'uRange')
    set_par(pointcloud, ['value0x'], 2.0)

    outs = [('color', color), ('depth_mm', depth_mm), ('ir', ir), ('pointcloud', pointcloud)]
    for i, (name, source_top) in enumerate(outs):
        out = comp.create(outTOP, 'out_' + name)
        out.nodeX, out.nodeY = 750, 300 - 150 * i
        out.inputConnectors[0].connect(source_top)

    if ROOT:
        path = os.path.join(ROOT, 'dklink.tox')
        comp.save(path)
        print('dklink: saved', path)
    print('dklink: built', comp.path)
    return comp


build()
