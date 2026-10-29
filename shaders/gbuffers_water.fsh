#version 330 compatibility

uniform sampler2D lightmap;
uniform sampler2D gtexture;
uniform float alphaTestRef = 0.1;

in vec2 lmcoord;
in vec2 texcoord;
in vec4 glcolor;
in vec3 normal;

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 color;
layout(location = 1) out vec4 outLightmap;
layout(location = 2) out vec4 outNormal;

const float darknessFactor = 0.35;

void main() {
    vec4 texColor = texture(gtexture, texcoord) * glcolor;
    vec4 light    = texture(lightmap, lmcoord);
    color = texColor * light;
    color.rgb *= darknessFactor;

    if (color.a < alphaTestRef) {
        discard;
    }

    outLightmap = vec4(lmcoord, 0.0, 1.0);
    outNormal = vec4(normalize(normal) * 0.5 + 0.5, 1.0);
}
