package com.example.team_run_challenge

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

class OnboardingActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val textView = TextView(this).apply {
            text = "Připojte aplikaci k Health Connect a povolte přístup k datům o vzdálenosti."
            textSize = 18f
            setPadding(32, 32, 32, 32)
        }

        setContentView(textView)
    }
}
