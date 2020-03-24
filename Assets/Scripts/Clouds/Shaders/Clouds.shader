
Shader "Hidden/Clouds"
{

    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
    
        // No culling or depth
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            CGPROGRAM

            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"
            #include "Assets/Scripts/Clouds/Shaders/CloudDebug.cginc"

            // vertex input: position, UV
            struct appdata {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f {
                float4 pos : SV_POSITION;
                float2 uv : TEXCOORD0;
                float3 viewVector : TEXCOORD1;
            };

            v2f vert (appdata v) {
                v2f output;
                output.pos = UnityObjectToClipPos(v.vertex);
                output.uv = v.uv;
                // Camera space matches OpenGL convention where cam forward is -z. In unity forward is positive z.
                // (https://docs.unity3d.com/ScriptReference/Camera-cameraToWorldMatrix.html)
                float3 viewVector = mul(unity_CameraInvProjection, float4(v.uv * 2 - 1, 0, -1));
                output.viewVector = mul(unity_CameraToWorld, float4(viewVector,0));
                return output;
            }

            // Textures
            // The main cloud texture
            Texture3D<float4> NoiseTex;
            // Whisps and detailing
            Texture3D<float4> DetailNoiseTex;
            // Larger scale 2D texture, currently unused
            Texture2D<float4> WeatherMap;
            // 1D texture to give the 'thunderhead''vibe
            Texture2D<float> AltitudeMap;

            SamplerState samplerNoiseTex;
            SamplerState samplerDetailNoiseTex;
            SamplerState samplerWeatherMap;
            SamplerState samplerAltitudeMap;

            sampler2D _MainTex;
            sampler2D _CameraDepthTexture;

            // Shape settings
            // TODO: reorganize parameters (eg. phase into light setting)
            float4 params;
            int3 mapSize;
            // Pretty self-explanatory noise combination parameters
            float densityMultiplier;
            float densityOffset;
            float scale;
            float detailNoiseScale;
            float detailNoiseWeight;
            // Weights to balance the 4 channels of the detail shader
            float3 detailWeights;
            float4 shapeNoiseWeights;
            // Used for silverlining while looking at the sun, currently broken
            float4 phaseParams;
            // Private parameters to recreate altitudeMap's range
            float altitudeOffset;
            float altitudeMultiplier;

            // March settings
            int numStepsLight;
            float stepSizeRender;
            float rayOffsetStrength;
            // Two opposite corners of the cloud container
            float3 boundsMin;
            float3 boundsMax;
            // Used for offseting the noise patterns, currently unused
            float3 shapeOffset;
            float3 detailOffset;

            // Light settings
            float lightAbsorptionTowardSun;
            float lightAbsorptionThroughCloud;
            float darknessThreshold;
            float4 _LightColor0;
            float4 colA;
            float4 colB;

            // Animation settings
            float timeScale;
            float baseSpeed;
            float detailSpeed;

            // Debug settings:
            // Allow the 'picture in a picture' noise editing tool
            // TODO: Will need to be heavily changed to remove this shader from the camera
            int debugViewMode; // 0 = off; 1 = shape tex; 2 = detail tex; 3 = weathermap, 4 = altitudemap
            int debugGreyscale;
            int debugShowAllChannels;
            float debugNoiseSliceDepth;
            float4 debugChannelWeight;
            float debugTileAmount;
            float viewerSize;

            // Maps a float from an interval to another, without bound checking
            float remap(float v, float minOld, float maxOld, float minNew, float maxNew) {
                return minNew + (v-minOld) * (maxNew - minNew) / (maxOld-minOld);
            }

            float2 squareUV(float2 uv) {
                float width = _ScreenParams.x;
                float height =_ScreenParams.y;
                //float minDim = min(width, height);
                float scale = 1000;
                float x = uv.x * width;
                float y = uv.y * height;
                return float2 (x/scale, y/scale);
            }

            // Returns (dstToBox, dstInsideBox). If ray misses box, dstInsideBox will be zero
            float2 rayBoxDst(float3 boundsMin, float3 boundsMax, float3 rayOrigin, float3 invRaydir) {
                // Adapted from: http://jcgt.org/published/0007/03/04/
                float3 t0 = (boundsMin - rayOrigin) * invRaydir;
                float3 t1 = (boundsMax - rayOrigin) * invRaydir;
                float3 tmin = min(t0, t1);
                float3 tmax = max(t0, t1);

                float dstA = max(max(tmin.x, tmin.y), tmin.z);
                float dstB = min(tmax.x, min(tmax.y, tmax.z));

                // CASE 1: ray intersects box from outside (0 <= dstA <= dstB)
                // dstA is dst to nearest intersection, dstB dst to far intersection

                // CASE 2: ray intersects box from inside (dstA < 0 < dstB)
                // dstA is the dst to intersection behind the ray, dstB is dst to forward intersection

                // CASE 3: ray misses box (dstA > dstB)

                float dstToBox = max(0, dstA);
                float dstInsideBox = max(0, dstB - dstToBox);
                return float2(dstToBox, dstInsideBox);
            }

            // Henyey-Greenstein
            float hg(float a, float g) {
                float g2 = g*g;
                return (1-g2) / (4*3.1415*pow(1+g2-2*g*(a), 1.5));
            }

            float phase(float a) {
                float blend = .5;
                float hgBlend = hg(a,phaseParams.x) * (1-blend) + hg(a,-phaseParams.y) * blend;
                return phaseParams.z + hgBlend*phaseParams.w;
            }

            float beer(float d) {
                float beer = exp(-d);
                return beer;
            }

            float remap01(float v, float low, float high) {
                return (v-low)/(high-low);
            }

            float altitudeDensity(float heightPercent)
            {
                return AltitudeMap.SampleLevel(samplerAltitudeMap, heightPercent, 0) * altitudeMultiplier + altitudeOffset;
            }

            float sampleDensity(float3 rayPos) {
                // Constants:
                const int mipLevel = 2;
                const float baseScale = 1/1000.0;

                // Calculate texture sample positions
                float time = _Time.x * timeScale;
                float3 size = boundsMax - boundsMin;
                float3 boundsCentre = (boundsMin+boundsMax) * .5;
                float3 uvw = (size * .5 + rayPos) * baseScale * scale;
                float3 shapeSamplePos = uvw + float3(time,time*0.1,time*0.2) * baseSpeed;

                // Calculate height gradient from weather map
                // Currently fully disabled
                //float2 weatherUV = (size.xz * .5 + (rayPos.xz-boundsCentre.xz)) / max(size.x,size.z);
                //float weatherMap = WeatherMap.SampleLevel(samplerWeatherMap, weatherUV, 1).x * 100;

                // Sets a gradient tapering off at the top and bottom, avoiding ugly flat spots (which tend to look buggy)
                float gMin = 0.1;//remap(weatherMap.x,0,1,0.1,0.5);
                float gMax = 0.9;//remap(weatherMap.x,0,1,gMin,0.9);
                float heightPercent = (rayPos.y - boundsMin.y) / size.y;
                float heightGradient = pow(saturate(remap(heightPercent, 0.0, gMin, 0, 1)) * saturate(remap(heightPercent, 1, gMax, 0, 1)), 0.1);


                // Calculate meta shape density
                // Duplicated code to create a meta layer of clouds
                // TODO: Fully seperate from normal noise settings
                //float3 shapeSamplePosMeta = shapeSamplePos / 10;
                //shapeSamplePosMeta.y /= 1.5;
                float3 shapeSamplePosMeta = uvw;
                shapeSamplePosMeta /= 10;
                shapeSamplePosMeta.y /= 1.5;


                float4 shapeNoiseMeta = NoiseTex.SampleLevel(samplerNoiseTex, shapeSamplePosMeta , mipLevel);
                float4 normalizedShapeWeightsMeta = shapeNoiseWeights / dot(shapeNoiseWeights, 1);
                float shapeFBMMeta = dot(shapeNoiseMeta, normalizedShapeWeightsMeta) * heightGradient;
                float baseShapeDensityMeta = (shapeFBMMeta + densityOffset * .1 - 0.1) * 15;

                // Add altitude density
                // TODO: standardize height gradient inside density
                baseShapeDensityMeta += altitudeDensity(heightPercent) * heightGradient;

                // Try early returning, might be ignored by compiler since forking is hard on GPU
                if (baseShapeDensityMeta < -1)
                    return 0;

                // Calculate base shape density
                float4 shapeNoise = NoiseTex.SampleLevel(samplerNoiseTex, shapeSamplePos, mipLevel);
                float4 normalizedShapeWeights = shapeNoiseWeights / dot(shapeNoiseWeights, 1);
                float shapeFBM = dot(shapeNoise, normalizedShapeWeights) * heightGradient;
                float baseShapeDensity = baseShapeDensityMeta * heightGradient + shapeFBM + densityOffset * .1;

                // Save sampling from detail tex if shape density <= 0
                if (baseShapeDensity > 0) {
                    // Sample detail noise
                    float3 detailSamplePos = uvw*detailNoiseScale + float3(time*.4,-time,time*0.1)*detailSpeed;
                    float4 detailNoise = DetailNoiseTex.SampleLevel(samplerDetailNoiseTex, detailSamplePos, mipLevel);
                    float3 normalizedDetailWeights = detailWeights / dot(detailWeights, 1);
                    float detailFBM = dot(detailNoise, normalizedDetailWeights);

                    // Subtract detail noise from base shape (weighted by inverse density so that edges get eroded more than centre)
                    float oneMinusShape = 1 - shapeFBM;
                    float detailErodeWeight = oneMinusShape * oneMinusShape * oneMinusShape;
                    float cloudDensity = baseShapeDensity - (1-detailFBM) * detailErodeWeight * detailNoiseWeight;

                    return cloudDensity * densityMultiplier * 0.1;
                }
                return 0;
            }

            // Calculate proportion of light that reaches the given point from the lightsource
            float lightmarch(float3 position) {
                float3 dirToLight = _WorldSpaceLightPos0.xyz;
                float dstInsideBox = rayBoxDst(boundsMin, boundsMax, position, 1/dirToLight).y;

                float stepSize = dstInsideBox/numStepsLight;
                position += dirToLight * stepSize * .5;
                float totalDensity = 0;
                float dstTravelled = 0;

                for (int step = 0; step < numStepsLight; step ++) {
                    float density = sampleDensity(position);
                    totalDensity += max(0, density * stepSize);

                    //Try early returning if less than 0.01 is passing through
                    if (totalDensity > -log(0.2) * lightAbsorptionTowardSun)
                        break;
                    //Variable stepping, using the noise like a signed-distance-function
                    //Works well if hard contrast is avoided
                    float dst = stepSize * max(abs(density), 1);
                    position += dirToLight * dst;
                    dstTravelled += dst;
                    //Due to variable stepping, skip if end is reached, probably no effect on perf
                    if (dstTravelled >= dstInsideBox)
                        break;
                }
                float transmittance = beer(totalDensity*lightAbsorptionTowardSun);
	
                float clampedTransmittance = darknessThreshold + transmittance * (1-darknessThreshold);
                return clampedTransmittance;
            }

            float4 debugDrawNoise(float2 uv) {

                float4 channels = 0;
                float3 samplePos = float3(uv.x,uv.y, debugNoiseSliceDepth);

                if (debugViewMode == 1) {
                    channels = NoiseTex.SampleLevel(samplerNoiseTex, samplePos, 0);
                }
                else if (debugViewMode == 2) {
                    channels = DetailNoiseTex.SampleLevel(samplerDetailNoiseTex, samplePos, 0);
                }
                else if (debugViewMode == 3) {
                    channels = WeatherMap.SampleLevel(samplerWeatherMap, samplePos.xy, 0);
                } else if (debugViewMode == 4) {
                    channels = AltitudeMap.SampleLevel(samplerAltitudeMap, samplePos.yy, 0);
                }

                if (debugShowAllChannels) {
                    return channels;
                }
                else {
                    float4 maskedChannels = (channels*debugChannelWeight);
                    if (debugGreyscale || debugChannelWeight.w == 1) {
                        return dot(maskedChannels,1);
                    }
                    else {
                        return maskedChannels;
                    }
                }
            }

            // Returns a multiplier used to change the step-size depending on distance to camera,
            // or similar optimizations, might be changed for higher precision close
            float getPrecision(Vector pos)
            {
                return 1 / max(length(pos) / 200, 1);
            }

            float4 frag (v2f i) : SV_Target
            {
                #if DEBUG_MODE == 1
                if (debugViewMode != 0) {
                    float width = _ScreenParams.x;
                    float height =_ScreenParams.y;
                    float minDim = min(width, height);
                    float x = i.uv.x * width;
                    float y = (1-i.uv.y) * height;

                    if (x < minDim*viewerSize && y < minDim*viewerSize) {
                        return debugDrawNoise(float2(x/(minDim*viewerSize)*debugTileAmount, y/(minDim*viewerSize)*debugTileAmount));
                    }
                }
                #endif

                // Create ray
                float3 rayPos = _WorldSpaceCameraPos;
                float viewLength = length(i.viewVector);
                float3 rayDir = i.viewVector / viewLength;

                // Depth and cloud container intersection info:
                float nonlin_depth = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, i.uv);
                float depth = LinearEyeDepth(nonlin_depth) * viewLength;
                float2 rayToContainerInfo = rayBoxDst(boundsMin, boundsMax, rayPos, 1/rayDir);
                float dstToBox = rayToContainerInfo.x;
                float dstInsideBox = rayToContainerInfo.y;

                // point of intersection with the cloud container
                float3 entryPoint = rayPos + rayDir * dstToBox;

                // random starting offset (makes low-res results noisy rather than jagged/glitchy, which is nicer)
                // removed, as signed distance function approach works better
                //float randomOffset = BlueNoise.SampleLevel(samplerBlueNoise, squareUV(i.uv*3), 0);
                //randomOffset *= rayOffsetStrength;

                // Phase function makes clouds brighter around sun
                float cosAngle = dot(rayDir, _WorldSpaceLightPos0.xyz);
                float phaseVal = phase(cosAngle);

                float dstTravelled = 1;//randomOffset;
                float dstLimit = min(depth-dstToBox, dstInsideBox);

                float stepSize = stepSizeRender;

                // March through volume:
                float transmittance = 1;

                // a float3 for reasons unknown
                // honestly I have no idea why that's needed, it looks like it always has equal values
                float3 lightEnergy = 0;

                while (dstTravelled < dstLimit) {
                    rayPos = entryPoint + rayDir * dstTravelled;
                    float precision = getPrecision(dstTravelled + dstToBox);
                    float density = sampleDensity(rayPos);

                    if (density > 0) {
                        float lightTransmittance = lightmarch(rayPos);
                        transmittance *= exp(-density * stepSize * lightAbsorptionThroughCloud);
                        lightEnergy += density * stepSize * transmittance * lightTransmittance * phaseVal;

                        // Exit early if T is close to zero as further samples won't affect the result much
                        if (transmittance < 0.01) {
                            break;
                        }
                    }
                    dstTravelled += stepSize * max(abs(density), 0.01) * 2 / precision;
                }

                // Composite sky + background
                // float3 skyColBase = lerp(colA,colB, sqrt(abs(saturate(rayDir.y))));
                float3 backgroundCol = tex2D(_MainTex,i.uv);
                // float dstFog = 1-exp(-max(0,depth) * 8*.0001);
                // float3 sky = dstFog * skyColBase;
                // backgroundCol = backgroundCol * (1-dstFog) + backgroundCol;

                // Sun
                float focusedEyeCos = pow(saturate(cosAngle), params.x);
                float sun = saturate(hg(focusedEyeCos, .995)) * transmittance;

                lightEnergy = pow((saturate(lightEnergy * 0.7)), 2);
                sun = saturate(sun);
                transmittance = sqrt(saturate(transmittance));

                // Add clouds
                float3 cloudCol = lerp(colA, _LightColor0, lightEnergy);
                float3 col = lerp(cloudCol, backgroundCol, transmittance);
                col = lerp(col, float3(1,1,1), sun);
                return float4(col,0);

            }

            ENDCG
        }
    }
}