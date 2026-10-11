class_name DShaders
extends RefCounted
## AUTOMATISCH ERZEUGT aus shadegunner.render.shaders (tools/export_data.py) - nicht von Hand ändern.

const CRT_LEVEL = {
	"curve": 0.06,
	"mask": 0.22,
	"scan": 0.3,
	"bloom": 0.7,
	"grain": 0.035,
	"hum": 0.02,
	"vignette": 0.4,
	"aberr": 1.5,
	"blur": 0.5,
	"tau": [0.016, 0.023, 0.013],
}
const GLSL_COMMON = "const vec3 PAL[32] = vec3[32](vec3(0.0235, 0.0314, 0.0549), vec3(0.0706, 0.0863, 0.1490), vec3(0.1333, 0.1569, 0.2588), vec3(0.2039, 0.2353, 0.3765), vec3(0.2902, 0.3608, 0.5412), vec3(0.4078, 0.5176, 0.6980), vec3(0.5412, 0.1255, 0.2196), vec3(0.6118, 0.3294, 0.1569), vec3(0.6353, 0.6588, 0.7059), vec3(0.8392, 0.8627, 0.8863), vec3(1.0000, 1.0000, 1.0000), vec3(0.1333, 0.3765, 0.4078), vec3(0.2510, 0.8235, 0.8627), vec3(0.8784, 0.2824, 0.5882), vec3(1.0000, 0.5412, 0.1725), vec3(0.4784, 0.2902, 0.6588), vec3(0.0000, 0.0000, 0.0000), vec3(0.0000, 0.0000, 0.6667), vec3(0.0000, 0.6667, 0.0000), vec3(0.0000, 0.6667, 0.6667), vec3(0.6667, 0.0000, 0.0000), vec3(0.6667, 0.0000, 0.6667), vec3(0.6667, 0.3333, 0.0000), vec3(0.6667, 0.6667, 0.6667), vec3(0.3333, 0.3333, 0.3333), vec3(0.3333, 0.3333, 1.0000), vec3(0.3333, 1.0000, 0.3333), vec3(0.3333, 1.0000, 1.0000), vec3(1.0000, 0.3333, 0.3333), vec3(1.0000, 0.3333, 1.0000), vec3(1.0000, 1.0000, 0.3333), vec3(1.0000, 1.0000, 1.0000));\n\nvec3 nearest_pal(vec3 c, int off, int n) {\n    vec3 best = PAL[off];\n    float bd = 1e9;\n    for (int i = 0; i < 32; ++i) {\n        if (i >= n) break;\n        vec3 q = PAL[off + i];\n        vec3 d = (c - q) * vec3(0.9, 1.1, 0.8);\n        float dd = dot(d, d);\n        if (dd < bd) { bd = dd; best = q; }\n    }\n    return best;\n}\nfloat bayer(ivec2 p, int k) {\n    int v = 0; int x = p.x; int y = p.y;\n    for (int i = 0; i < k; ++i) {\n        v = (v << 2) | (((x ^ y) & 1) << 1) | (y & 1);\n        x >>= 1; y >>= 1;\n    }\n    return (float(v) + 0.5) / float(1 << (2 * k));\n}\n"
const PAL_OFFSETS = {"noir16": 0, "cga16": 16}
