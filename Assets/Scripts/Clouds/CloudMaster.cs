﻿using System.Collections;
using System.Collections.Generic;
using UnityEngine;

[ExecuteInEditMode, ImageEffectAllowedInSceneView]
public class CloudMaster : MonoBehaviour {
    const string headerDecoration = " --- ";
    [Header (headerDecoration + "Main" + headerDecoration)]
    public Shader shader;
    public Transform container;
    public Vector3 cloudTestParams;

    [Header (headerDecoration + "March settings" + headerDecoration)]
    public float stepSizeRender = 8;
    public int numStepsLight = 8;
    public float rayOffsetStrength;
    public Texture2D heightGradientTex;

    [Header (headerDecoration + "Base Shape" + headerDecoration)]
    public float cloudScale = 1;
    public float densityMultiplier = 1;
    public float densityOffset;
    public Vector3 shapeOffset;
    public Vector2 heightOffset;
    public Vector4 shapeNoiseWeights;

    [Header (headerDecoration + "Detail" + headerDecoration)]
    public float detailNoiseScale = 10;
    public float detailNoiseWeight = .1f;
    public Vector3 detailNoiseWeights;
    public Vector3 detailOffset;

    [Header (headerDecoration + "Lighting" + headerDecoration)]
    public float lightAbsorptionThroughCloud = 1;
    public float lightAbsorptionTowardSun = 1;
    [Range (0, 1)]
    public float darknessThreshold = .2f;
    [Range (0, 1)]
    public float forwardScattering = .83f;
    [Range (0, 1)]
    public float backScattering = .3f;
    [Range (0, 1)]
    public float baseBrightness = .8f;
    [Range (0, 1)]
    public float phaseFactor = .15f;

    [Header (headerDecoration + "Animation" + headerDecoration)]
    public float timeScale = 1;
    public float baseSpeed = 1;
    public float detailSpeed = 2;

    [Header (headerDecoration + "Sky" + headerDecoration)]
    public Color colA;
    public Color colB;

    // Internal
    [HideInInspector]
    public Material material;

    // The texture generators for the shader
    // TODO: standardize noise generators
    // TODO: allow multiple coexisting generators ?
    // TODO: force the generators on the same object using [Require] ?
    private WeatherMap weatherMapGen;
    private AltitudeMap altitudeMapGen;
    private NoiseGenerator noiseGen;

    void UpdateMaps()
    {
        weatherMapGen = FindObjectOfType<WeatherMap> ();
        altitudeMapGen = FindObjectOfType<AltitudeMap> ();
        noiseGen = FindObjectOfType<NoiseGenerator> ();
        weatherMapGen.UpdateMap ();
        altitudeMapGen.UpdateMap ();
    }

    void Awake () {
        if (Application.isPlaying)
            UpdateMaps();
    }

    [ImageEffectOpaque]
    private void OnRenderImage (RenderTexture src, RenderTexture dest) {

        // Validate inputs
        if (material == null || material.shader != shader) {
            material = new Material (shader);
        }
        numStepsLight = Mathf.Max (1, numStepsLight);
        stepSizeRender = Mathf.Max(5, stepSizeRender);

        // Noise
        var noise = FindObjectOfType<NoiseGenerator> ();
        noise.UpdateNoise ();

        material.SetTexture ("NoiseTex", noise.shapeTexture);
        material.SetTexture ("DetailNoiseTex", noise.detailTexture);
        material.SetTexture ("HeightGradientTex", heightGradientTex);

        // WeatherMap and AltitudeMap
        UpdateMaps();
        material.SetTexture ("WeatherMap", weatherMapGen.weatherMap);
        material.SetTexture ("AltitudeMap", altitudeMapGen.altitudeMap);
        material.SetFloat("altitudeOffset", altitudeMapGen.altitudeOffset);
        material.SetFloat("altitudeMultiplier", altitudeMapGen.altitudeMultiplier);

        Vector3 size = container.localScale;
        int width = Mathf.CeilToInt (size.x);
        int height = Mathf.CeilToInt (size.y);
        int depth = Mathf.CeilToInt (size.z);

        material.SetFloat ("scale", cloudScale);
        material.SetFloat ("densityMultiplier", densityMultiplier);
        material.SetFloat ("densityOffset", densityOffset);
        material.SetFloat ("lightAbsorptionThroughCloud", lightAbsorptionThroughCloud);
        material.SetFloat ("lightAbsorptionTowardSun", lightAbsorptionTowardSun);
        material.SetFloat ("darknessThreshold", darknessThreshold);
        material.SetVector ("params", cloudTestParams);
        material.SetFloat ("rayOffsetStrength", rayOffsetStrength);

        material.SetFloat ("detailNoiseScale", detailNoiseScale);
        material.SetFloat ("detailNoiseWeight", detailNoiseWeight);
        material.SetVector ("shapeOffset", shapeOffset);
        material.SetVector ("detailOffset", detailOffset);
        material.SetVector ("detailWeights", detailNoiseWeights);
        material.SetVector ("shapeNoiseWeights", shapeNoiseWeights);
        material.SetVector ("phaseParams", new Vector4 (forwardScattering, backScattering, baseBrightness, phaseFactor));

        material.SetVector ("boundsMin", container.position - container.localScale / 2);
        material.SetVector ("boundsMax", container.position + container.localScale / 2);

        material.SetInt ("numStepsLight", numStepsLight);
        material.SetFloat("stepSizeRender", stepSizeRender);

        material.SetVector ("mapSize", new Vector4 (width, height, depth, 0));

        material.SetFloat ("timeScale", (Application.isPlaying) ? timeScale : 0);
        material.SetFloat ("baseSpeed", baseSpeed);
        material.SetFloat ("detailSpeed", detailSpeed);

        // Set debug params
        SetDebugParams ();

        material.SetColor ("colA", colA);
        material.SetColor ("colB", colB);

        // Blit does the following:
        // - sets _MainTex property on material to the source texture
        // - sets the render target to the destination texture
        // - draws a full-screen quad
        // This copies the src texture to the dest texture, with whatever modifications the shader makes
        Graphics.Blit (src, dest, material);
    }

    void SetDebugParams () {

        int debugModeIndex = 0;
        var noise = this.noiseGen;
        if (noise.viewerEnabled) {
            debugModeIndex = (noise.activeTextureType == NoiseGenerator.CloudNoiseType.Shape) ? 1 : 2;
        }
        if (weatherMapGen.viewerEnabled) {
            debugModeIndex = 3;
        }
        if (altitudeMapGen.viewerEnabled) {
            debugModeIndex = 4;
        }

        material.SetInt ("debugViewMode", debugModeIndex);
        material.SetFloat ("debugNoiseSliceDepth", noise.viewerSliceDepth);
        material.SetFloat ("debugTileAmount", noise.viewerTileAmount);
        material.SetFloat ("viewerSize", noise.viewerSize);
        material.SetVector ("debugChannelWeight", noise.ChannelMask);
        material.SetInt ("debugGreyscale", (noise.viewerGreyscale) ? 1 : 0);
        material.SetInt ("debugShowAllChannels", (noise.viewerShowAllChannels) ? 1 : 0);
    }

}