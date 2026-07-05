package com.example.team_run_challenge

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

class PermissionsRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val textView = TextView(this).apply {
            text = "Tato aplikace používá Health Connect pro čtení vzdálenosti potřebné pro vaši výzvu."
            textSize = 18f
            setPadding(32, 32, 32, 32)
        }

        setContentView(textView)
    }
}
