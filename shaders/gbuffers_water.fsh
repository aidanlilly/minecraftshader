#version 330 compatibility

// --- Uniforms ---
uniform sampler2D lightmap;
uniform sampler2D gtexture;
uniform mat4 gbufferProjectionInverse;
uniform float alphaTestRef = 0.1;

// --- Inputs ---
in vec2 lmcoord;
in vec2 texcoord;
in vec4 glcolor;

/* RENDERTARGETS: 0,1,2 */
layout(location = 0) out vec4 color;
layout(location = 1) out vec4 outLightmap;
layout(location = 2) out vec4 outNormal;

const float darknessFactor = 0.35;

void main() {
    vec4 texColor = texture(gtexture, texcoord) * glcolor;
    vec4 light    = texture(lightmap, lmcoord);
    vec3 normal   = vec3(0.0, 1.0, 0.0);

    color = texColor * light;
    color.rgb *= darknessFactor;

    if (color.a < alphaTestRef) {
        discard;
    }

    outLightmap = vec4(lmcoord, 0.0, 1.0);
    outNormal = vec4(normal * 0.5 + 0.5, 1.0); // .a = 1.0 flags water for SSR
}