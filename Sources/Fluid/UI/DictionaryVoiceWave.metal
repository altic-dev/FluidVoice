#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Glowing voice ribbon for the dictionary recording step.
// phase moves the strands; energy (0...1) is the smoothed microphone level.
[[ stitchable ]] half4 dictionaryVoiceWave(float2 position, half4 color, float2 size, float phase, float energy, float dark) {
    float x = position.x / size.x;
    float y = position.y - size.y * 0.5;

    // Strands fade in and out at both ends instead of stopping at a hard edge, and their glow
    // fades out before the top and bottom so the frame never shows as a box.
    float ends = smoothstep(0.0, 0.18, x) * smoothstep(1.0, 0.82, x)
        * (1.0 - smoothstep(0.55, 1.0, abs(y) / (size.y * 0.5)));
    float envelope = sin(M_PI_F * x);

    // The ribbon takes its ink from the color it paints over, so the theme owns it.
    float3 tint = color.a > 0.0h ? float3(color.rgb) / float(color.a) : float3(1.0);

    float amplitude = size.y * (0.26 + 0.14 * energy);
    float glowWidth = 9.0 + 6.0 * energy;
    float3 light = float3(0.0);
    float hot = 0.0;
    float coreSum = 0.0;
    float glowSum = 0.0;

    for (int i = 0; i < 5; i++) {
        float f = float(i);
        float strandPhase = phase * (0.8 + 0.23 * f) + f * 1.9;
        float frequency = 0.85 + 0.3 * f;
        float wobble = 1.0 + 0.25 * sin(phase * 0.6 + f * 2.3);
        float strandY = amplitude * (1.0 - 0.17 * f) * wobble * envelope * sin(2.0 * M_PI_F * frequency * x + strandPhase);
        float d = abs(y - strandY);
        float weight = i == 0 ? 1.0 : 0.5 - 0.06 * f;
        float core = exp(-d * d / (2.0 * 1.1 * 1.1));
        float glow = exp(-d / glowWidth);
        light += tint * (core * 1.2 + glow * (0.5 + 0.15 * energy)) * weight;
        coreSum += core * weight;
        glowSum += glow * weight;
        if (i == 0) { hot = core; }
    }

    // Soft bloom behind the middle of the ribbon, stronger while speaking.
    float2 centre = float2((x - 0.5) * 2.2, y / (size.y * 0.5));
    float bloom = exp(-dot(centre, centre) * 2.2) * (0.22 + 0.12 * energy);

    if (dark < 0.5) {
        // Added light only washes out on a light background. Paint the ink instead:
        // opacity comes from the strands' strength, so the ink itself stays solid.
        float3 ink = tint;
        float coverage = saturate(coreSum * 0.95 + glowSum * (0.22 + 0.08 * energy) + bloom * 0.35) * ends;
        float3 shade = mix(ink, ink * 0.78, saturate(hot));
        return half4(half3(shade * coverage), half(coverage));
    }

    light += tint * bloom;

    light += float3(1.0) * hot * 0.75;
    light *= ends;

    float alpha = saturate(max(light.r, max(light.g, light.b)));
    float3 rgb = min(light, float3(alpha));
    return half4(half3(rgb), half(alpha));
}
