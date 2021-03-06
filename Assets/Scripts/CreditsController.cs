﻿using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
using UnityEngine.SceneManagement;

[RequireComponent(typeof(Text))]
public class CreditsController : MonoBehaviour
{
    void Start() {
        PlaythroughData data = GameObject.FindObjectOfType<PlaythroughData>();

        if (data) {
            Text display = GetComponent<Text>();
            string text = display.text;

            text = text.Replace("{MINUTES}", "" + Mathf.Floor(data.timeSinceGameStart / 60f));
            text = text.Replace("{SECONDS}", "" + Mathf.Floor(data.timeSinceGameStart % 60f));

            display.text = text;
        }
    }

    void Update() {
        if (Input.GetKeyDown(KeyCode.Space) || 
            Input.GetKeyDown(KeyCode.Escape)) {
                SceneManager.LoadScene(0);
            }

    }
}
