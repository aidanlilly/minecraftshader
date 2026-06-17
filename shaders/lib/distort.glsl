// Shadow sampler configuration
const bool shadowtex0Nearest = true;
const bool shadowtex1Nearest = true;
const bool shadowcolor0Nearest = true;

// Shadow map projection parameters
const int   shadowMapResolution = 2048;
const float shadowDistanceRenderMul = 1.0;

#define SHADOW_RANGE   4
#define SHADOW_RADIUS  1.0

// Coordinate transformations
vec3 distortShadowClipPos(vec3 shadowClipPos) {
    float radialDistance = length(shadowClipPos.xy);
    float distortionFactor = radialDistance + 0.1;

    shadowClipPos.xy /= distortionFactor;
    shadowClipPos.z  *= 0.5;
    
    return shadowClipPos;
}