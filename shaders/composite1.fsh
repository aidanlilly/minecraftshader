#version 330 compatibility

// Uniforms
uniform sampler2D colortex0;
uniform sampler2D depthtex0;

uniform float far;
uniform vec3  fogColor;
uniform int   isEyeInWater; // 0 = Air, 1 = Water, 2 = Lava

uniform mat4 gbufferProjectionInverse;

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 color;

// Configuration Constants
#define FOG_DENSITY_AIR   5.0
#define FOG_DENSITY_WATER 12.0 

const vec3 waterFogSkyFallback = vec3(0.02, 0.1, 0.15);
const vec3 waterFogAttenuation  = vec3(0.05, 0.15, 0.2);

// Mathematical Utilities
vec3 unproject(mat4 invProjection, vec3 ndc) {
    vec4 hyperSpacePos = invProjection * vec4(ndc, 1.0);
    return hyperSpacePos.xyz / hyperSpacePos.w;
}

// Main Executable Entrypoint
void main() {
    color = texture(colortex0, texcoord);

    float sceneDepth = texture(depthtex0, texcoord).r;

    // Early Exit / Exception: Background sky environment
    if (sceneDepth == 1.0) {
        if (isEyeInWater == 1) {
            color.rgb = mix(color.rgb, waterFogSkyFallback, 0.9);
        }
        return;
    }

    // Coordinate Reconstruction
    vec3 ndcCoordinates = vec3(texcoord.xy, sceneDepth) * 2.0 - 1.0;
    vec3 viewPosition = unproject(gbufferProjectionInverse, ndcCoordinates);
    float normalizedDistance = length(viewPosition) / far;

    float fogFactor;
    vec3 finalFogColor;

    if (isEyeInWater == 1) {
        // Material Pass: Exponential Underwater Fog
        fogFactor = exp(-FOG_DENSITY_WATER * normalizedDistance); 
        finalFogColor = waterFogAttenuation;
        
        color.rgb = mix(finalFogColor, color.rgb, clamp(fogFactor, 0.0, 1.0));
    } else {
        // Material Pass: Atmospheric Air Fog (Inverse Horizon Blend)
        fogFactor = exp(-FOG_DENSITY_AIR * (1.0 - normalizedDistance));
        finalFogColor = pow(fogColor, vec3(2.2)); // Gamma Correction: Convert to linear space
        
        color.rgb = mix(color.rgb, finalFogColor, clamp(fogFactor, 0.0, 1.0));
    }
}