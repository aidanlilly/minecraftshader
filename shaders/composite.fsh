#version 330 compatibility

// Uniforms
uniform sampler2D depthtex0;
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
uniform sampler2D colortex0;      // Albedo
uniform sampler2D colortex1;      // Lightmap (RG)
uniform sampler2D colortex2;      // Normal (RGB), Water Mask (A)
uniform sampler2D noisetex;

uniform vec3  shadowLightPosition;
uniform mat4  gbufferModelViewInverse;
uniform mat4  gbufferProjectionInverse;
uniform mat4  gbufferProjection;
uniform mat4  shadowModelView;
uniform mat4  shadowProjection;
uniform float viewWidth;
uniform float viewHeight;
uniform int   isEyeInWater;

in vec2 texcoord;

#include "/lib/distort.glsl"

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 color;

// Configuration constants
// Shadows
#define SHADOW_RANGE   2
#define SHADOW_RADIUS  2.0
#define SHADOW_RES     2048.0

// Ambient Occlusion (AO)
#define AO_SAMPLES     16
#define AO_RADIUS      0.5

// Screen Space Reflections (SSR)
#define SSR_STEPS      80       // Maximum ray-march iterations
#define SSR_BIN_STEPS  8        // Binary refinement steps
#define SSR_MAXDIST    32.0     // Maximum ray length in world units
#define SSR_THICKNESS  0.5      // Surface intersection tolerance depth
#define SSR_EDGE_FADE  0.1      // Screen edge vignette fade factor (0.0 - 0.5)

// Material coefficients (Water)
#define WATER_F0       0.05     // Base specular reflectance at normal incidence
#define WATER_F_BOOST  3.0      // Reflectivity scaling factor for grazing angles
#define SKY_REFL_STR   0.15     // Fallback intensity for environmental sky reflection
#define SUN_SPEC_EXP   256.0    // Specular exponent (tightness) for solar reflection
#define SUN_SPEC_STR   0.8      // Intensity modifier for solar specular reflection

// Color space constants
const vec3 blocklightColor = vec3(1.0, 0.5, 0.08);
const vec3 skylightColor   = vec3(0.05, 0.15, 0.3);
const vec3 sunlightColor   = vec3(1.0, 0.98, 0.92);
const vec3 ambientColor    = vec3(0.1);
const vec3 shadowWeight    = vec3(0.3333333);

// Mathematical utilities
vec3 unproject(mat4 invProjection, vec3 ndc) {
    vec4 hyperSpacePos = invProjection * vec4(ndc, 1.0);
    return hyperSpacePos.xyz / hyperSpacePos.w;
}

vec4 sampleNoise(vec2 uv) {
    ivec2 texelCoords = ivec2(uv * vec2(viewWidth, viewHeight)) % 64;
    return texelFetch(noisetex, texelCoords, 0);
}

// Shadow mapping
vec3 sampleShadowMap(vec3 shadowSpacePos) {
    float bias = 0.001;
    float depthOpaque = texture(shadowtex0, shadowSpacePos.xy).r;
    float depthTransparent = texture(shadowtex1, shadowSpacePos.xy).r;
    
    if (shadowSpacePos.z - bias <= depthOpaque) {
        return vec3(1.0);
    }
    if (shadowSpacePos.z - bias > depthTransparent) {
        return vec3(0.0);
    }
    
    vec4 shadowColor = texture(shadowcolor0, shadowSpacePos.xy);
    return shadowColor.rgb * (1.0 - shadowColor.a);
}

vec3 getSoftShadow(vec4 shadowClip) {
    float angle = sampleNoise(texcoord).r * 6.2831853;
    mat2  rotationMatrix = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
    vec3  shadowAccumulator = vec3(0.0);
    int   sampleCount = 0;
    
    for (int x = -SHADOW_RANGE; x <= SHADOW_RANGE; x++) {
        for (int y = -SHADOW_RANGE; y <= SHADOW_RANGE; y++) {
            vec2 offset = rotationMatrix * (vec2(x, y) * (SHADOW_RADIUS / SHADOW_RES));
            vec3 ndc = shadowClip.xyz / shadowClip.w;
            ndc.xy += offset;
            ndc = distortShadowClipPos(ndc);
            
            shadowAccumulator += sampleShadowMap(ndc * 0.5 + 0.5);
            sampleCount++;
        }
    }
    return shadowAccumulator / float(sampleCount);
}

// Ambient occlusion
float getAO(vec3 viewPos, vec3 viewNormal) {
    float occlusion = 0.0;
    float baseAngle = sampleNoise(texcoord).r * 6.2831853;
    
    for (int i = 0; i < AO_SAMPLES; i++) {
        float sampleIdx = float(i) + 0.5;
        float radius = AO_RADIUS * sampleIdx / float(AO_SAMPLES);
        float angle = baseAngle + sampleIdx * 2.3999632;
        
        vec2 sampleUV = texcoord + vec2(cos(angle), sin(angle)) * radius / vec2(viewWidth, viewHeight);
        if (sampleUV != clamp(sampleUV, 0.0, 1.0)) continue;
        
        float sampleDepth = texture(depthtex0, sampleUV).r;
        if (sampleDepth == 1.0) continue;
        
        vec3 sampleViewPos = unproject(gbufferProjectionInverse, vec3(sampleUV * 2.0 - 1.0, sampleDepth * 2.0 - 1.0));
        vec3 positionDelta = sampleViewPos - viewPos;
        float distanceDelta = length(positionDelta);
        
        if (distanceDelta < 0.0001) continue;
        
        occlusion += (1.0 - max(0.0, dot(viewNormal, positionDelta / distanceDelta))) *
                     clamp(1.0 - distanceDelta / AO_RADIUS, 0.0, 1.0);
    }
    return clamp(occlusion / float(AO_SAMPLES), 0.0, 1.0);
}

// Screen space reflections
vec2 traceSSR(vec3 viewPos, vec3 reflectDir, out float hitFade) {
    hitFade = 0.0;

    float jitter = sampleNoise(texcoord).b;
    float stepLength = SSR_MAXDIST / float(SSR_STEPS);
    vec3 rayPosition = viewPos + reflectDir * stepLength * (0.5 + jitter * 0.5);

    for (int i = 0; i < SSR_STEPS; i++) {
        rayPosition += reflectDir * stepLength;

        vec4 clipSpacePos = gbufferProjection * vec4(rayPosition, 1.0);
        vec2 uv = clipSpacePos.xy / clipSpacePos.w * 0.5 + 0.5;

        if (uv != clamp(uv, 0.001, 0.999)) break;

        float depthBufferValue = texture(depthtex0, uv).r;
        if (depthBufferValue == 1.0) continue;

        vec3 surfaceViewPos = unproject(gbufferProjectionInverse, vec3(uv * 2.0 - 1.0, depthBufferValue * 2.0 - 1.0));
        float surfaceDepth = surfaceViewPos.z;

        if (rayPosition.z < surfaceDepth) {
            float depthDelta = surfaceDepth - rayPosition.z;
            if (depthDelta < SSR_THICKNESS) {
                // Binary Refinement Search
                vec3 rayRangeMin = rayPosition - reflectDir * stepLength;
                vec3 rayRangeMax = rayPosition;
                
                for (int b = 0; b < SSR_BIN_STEPS; b++) {
                    vec3 midPoint = (rayRangeMin + rayRangeMax) * 0.5;
                    vec4 midClip = gbufferProjection * vec4(midPoint, 1.0);
                    vec2 midUV = midClip.xy / midClip.w * 0.5 + 0.5;
                    
                    float midDepthVal = texture(depthtex0, midUV).r;
                    vec3 midSurfacePos = unproject(gbufferProjectionInverse, vec3(midUV * 2.0 - 1.0, midDepthVal * 2.0 - 1.0));
                    
                    if (midPoint.z < midSurfacePos.z) {
                        rayRangeMax = midPoint;
                    } else {
                        rayRangeMin = midPoint;
                    }
                }
                
                vec3 refinedRayPos = (rayRangeMin + rayRangeMax) * 0.5;
                vec4 refinedClip = gbufferProjection * vec4(refinedRayPos, 1.0);
                vec2 refinedUV = refinedClip.xy / refinedClip.w * 0.5 + 0.5;
                
                if (refinedUV != clamp(refinedUV, 0.0, 1.0)) break;

                // Edge and Distance Attenuation Calculating
                vec2 edgeAttenuation = smoothstep(0.0, SSR_EDGE_FADE, refinedUV) *
                                       smoothstep(1.0, 1.0 - SSR_EDGE_FADE, refinedUV);
                float distanceAttenuation = 1.0 - clamp(length(refinedRayPos - viewPos) / SSR_MAXDIST, 0.0, 1.0);

                hitFade = edgeAttenuation.x * edgeAttenuation.y * distanceAttenuation;
                return refinedUV;
            }
        }
    }
    return vec2(-1.0);
}

// Environment lighting
vec3 getSkyReflectionFallback(vec3 worldReflect, vec3 worldLightVec, vec2 lightmap, vec3 shadow) {
    float verticalFactor = clamp(worldReflect.y, 0.0, 1.0);
    
    vec3 zenithColor = skylightColor * 2.5;
    vec3 horizonColor = skylightColor * 1.5;
    vec3 environmentSky = mix(horizonColor, zenithColor, verticalFactor) * lightmap.g * SKY_REFL_STR;

    float specularDot = max(0.0, dot(worldReflect, worldLightVec));
    float sunSpecular = pow(specularDot, SUN_SPEC_EXP) * SUN_SPEC_STR;
    float shadowIntensity = dot(shadow, shadowWeight);
    
    environmentSky += sunlightColor * sunSpecular * shadowIntensity;
    return environmentSky;
}

float getWaterFresnel(vec3 viewDir, vec3 viewNormal) {
    float cosTheta = clamp(dot(-viewDir, viewNormal), 0.0, 1.0);
    float fresnelSchlick = WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - cosTheta, 5.0);
    return clamp(fresnelSchlick * WATER_F_BOOST, 0.15, 0.6);
}

// Main executable entrypoint
void main() {
    color = texture(colortex0, texcoord);
    color.rgb = pow(color.rgb, vec3(2.2)); // Gamma Correction: Convert to linear space

    float sceneDepth = texture(depthtex0, texcoord).r;
    if (sceneDepth == 1.0) return; // Early Exit: Background sky environment

    vec4 normalData = texture(colortex2, texcoord);
    vec3 surfaceNormal = normalize(normalData.rgb * 2.0 - 1.0);
    float waterMask = normalData.a;

    vec2 lightmapCoords = texture(colortex1, texcoord).rg;
    float handGeometryMask = texture(colortex1, texcoord).b;
    if (handGeometryMask > 0.5) return; // Early Exit: View-model pass optimization

    vec3 lightDirection = normalize(shadowLightPosition);
    vec3 worldLightDirection = mat3(gbufferModelViewInverse) * lightDirection;

    vec3 ndcCoordinates = vec3(texcoord, sceneDepth) * 2.0 - 1.0;
    vec3 viewPosition = unproject(gbufferProjectionInverse, ndcCoordinates);
    vec3 worldPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz;
    
    vec4 shadowClipPosition = shadowProjection * vec4((shadowModelView * vec4(worldPosition, 1.0)).xyz, 1.0);
    vec3 shadowAttenuation = getSoftShadow(shadowClipPosition);

    // Radiance Calculations
    float diffuseFactor = max(0.0, dot(worldLightDirection, surfaceNormal));
    vec3 lightSun = sunlightColor * diffuseFactor * shadowAttenuation;
    vec3 lightBlock = lightmapCoords.x * blocklightColor;
    vec3 lightSky = lightmapCoords.y * skylightColor;

    color.rgb *= (lightBlock + lightSky + ambientColor + lightSun);

    // Material Interaction: Water Surface Layer
    if (waterMask > 0.5 && isEyeInWater == 0) {
        mat3 worldToViewMatrix = transpose(mat3(gbufferModelViewInverse));
        vec3 viewSpaceNormal = normalize(worldToViewMatrix * surfaceNormal);
        vec3 viewDirection = normalize(viewPosition);
        vec3 reflectionVectorView = reflect(viewDirection, viewSpaceNormal);
        vec3 reflectionVectorWorld = mat3(gbufferModelViewInverse) * reflectionVectorView;

        float fresnelCoefficient = getWaterFresnel(viewDirection, viewSpaceNormal);
        vec3 fallbackColor = getSkyReflectionFallback(reflectionVectorWorld, worldLightDirection, lightmapCoords, shadowAttenuation);

        float reflectionHitFade = 0.0;
        vec2 reflectionHitUV = traceSSR(viewPosition, reflectionVectorView, reflectionHitFade);
        vec3 finalReflectionColor;

        if (reflectionHitUV.x >= 0.0 && reflectionHitFade > 0.0) {
            vec3 hitPointBufferColor = pow(texture(colortex0, reflectionHitUV).rgb, vec3(2.2));
            finalReflectionColor = mix(fallbackColor, hitPointBufferColor, reflectionHitFade);
        } else {
            finalReflectionColor = fallbackColor;
        }

        color.rgb = mix(color.rgb, finalReflectionColor, fresnelCoefficient);
    }
}