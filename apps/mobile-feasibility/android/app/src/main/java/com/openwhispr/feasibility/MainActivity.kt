package com.openwhispr.feasibility

import android.annotation.SuppressLint
import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.openwhispr.feasibility.accessibility.AccessibilityServiceRegistry
import com.openwhispr.feasibility.accessibility.OpenWhisprAccessibilityService
import com.openwhispr.feasibility.recording.RecordingService

@SuppressLint("SetTextI18n")
class MainActivity : android.app.Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var statusView: TextView
    private lateinit var setupView: TextView
    private lateinit var fixtureCheckBox: CheckBox
    private val refreshRunnable = object : Runnable {
        override fun run() {
            refreshStatus()
            handler.postDelayed(this, STATUS_REFRESH_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildContent())
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
        handler.removeCallbacks(refreshRunnable)
        handler.post(refreshRunnable)
    }

    override fun onPause() {
        handler.removeCallbacks(refreshRunnable)
        super.onPause()
    }

    private fun buildContent(): ScrollView {
        val density = resources.displayMetrics.density
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20, density), dp(20, density), dp(20, density), dp(28, density))
            setBackgroundColor(Color.rgb(247, 248, 252))
        }

        content.addView(TextView(this).apply {
            text = "OpenWhispr Android feasibility spike"
            textSize = 24f
            setTextColor(Color.rgb(22, 55, 127))
        }, fullWidthParams(bottom = 10, density = density))

        content.addView(TextView(this).apply {
            text = "This standalone Kotlin app keeps your existing keyboard selected. " +
                "It observes focused editable fields through Android AccessibilityService, " +
                "shows a non-focusable floating microphone while the keyboard is visible, " +
                "and exercises safe whole-field insertion on approved plain text editors."
            textSize = 16f
            setTextColor(Color.DKGRAY)
        }, fullWidthParams(bottom = 16, density = density))

        content.addView(TextView(this).apply {
            text = "Accessibility access is visible to the user and is used only for focused editable target capture and insertion validation. The service does not read or persist unrelated screen content."
            textSize = 14f
            setTextColor(Color.DKGRAY)
        }, fullWidthParams(bottom = 16, density = density))

        content.addView(button("Open accessibility settings") {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }, fullWidthParams(bottom = 8, density = density))

        content.addView(button("Grant floating microphone permission") {
            if (!Settings.canDrawOverlays(this)) {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName"),
                    ),
                )
            }
        }, fullWidthParams(bottom = 8, density = density))

        content.addView(button("Grant microphone permission") {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE)
            }
        }, fullWidthParams(bottom = 12, density = density))

        fixtureCheckBox = CheckBox(this).apply {
            text = getString(com.openwhispr.feasibility.R.string.fixture_mode_label)
            textSize = 15f
            isChecked = getSharedPreferences(AppPreferences.NAME, Context.MODE_PRIVATE)
                .getBoolean(AppPreferences.FIXTURE_MODE, false)
            setOnCheckedChangeListener { _, checked ->
                getSharedPreferences(AppPreferences.NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(AppPreferences.FIXTURE_MODE, checked)
                    .apply()
                refreshStatus()
            }
        }
        content.addView(fixtureCheckBox, fullWidthParams(bottom = 16, density = density))

        setupView = TextView(this).apply {
            textSize = 14f
            setTextColor(Color.DKGRAY)
        }
        content.addView(setupView, fullWidthParams(bottom = 12, density = density))

        statusView = TextView(this).apply {
            textSize = 15f
            setTextColor(Color.rgb(22, 55, 127))
        }
        content.addView(statusView, fullWidthParams(bottom = 12, density = density))

        content.addView(TextView(this).apply {
            text = "Fixture mode inserts the clearly labeled text \"[OpenWhispr fixture transcript] ...\" after a real microphone capture. It is off by default. With fixture mode off, this spike captures and discards PCM; cloud transcription is intentionally not included."
            textSize = 14f
            setTextColor(Color.DKGRAY)
        }, fullWidthParams(bottom = 12, density = density))

        content.addView(TextView(this).apply {
            text = "Device evidence is required before treating any app, keyboard, secure field, or editor as supported. See README.md for the acceptance matrix."
            textSize = 14f
            setTextColor(Color.DKGRAY)
        }, fullWidthParams(bottom = 12, density = density))

        return ScrollView(this).apply {
            addView(content)
        }
    }

    private fun refreshStatus() {
        if (!::setupView.isInitialized || !::statusView.isInitialized) return
        val accessibility = AccessibilityServiceRegistry.current()
        val accessibilityEnabled = isAccessibilityServiceEnabled()
        val overlayGranted = Settings.canDrawOverlays(this)
        val microphoneGranted = checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

        setupView.text = buildString {
            append("Setup\n")
            append(if (accessibilityEnabled) "✓" else "•")
            append(" Accessibility service enabled\n")
            append(if (overlayGranted) "✓" else "•")
            append(" Floating overlay permission granted\n")
            append(if (microphoneGranted) "✓" else "•")
            append(" Microphone permission granted\n")
            append(if (fixtureCheckBox.isChecked) "Fixture insertion mode: ON (explicit)" else "Fixture insertion mode: OFF")
        }
        statusView.text = buildString {
            append("Service status: ")
            append(accessibility?.statusText() ?: "Accessibility service not connected")
            append("\nMicrophone status: ")
            append(RecordingService.statusText())
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
        ) ?: return false
        val expected = ComponentName(this, OpenWhisprAccessibilityService::class.java)
            .flattenToString()
        return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
    }

    private fun button(label: String, action: () -> Unit): Button = Button(this).apply {
        text = label
        setOnClickListener { action() }
    }

    private fun fullWidthParams(bottom: Int, density: Float): LinearLayout.LayoutParams =
        LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply {
            bottomMargin = dp(bottom, density)
        }

    private fun dp(value: Int, density: Float): Int = (value * density).toInt()

    companion object {
        private const val REQUEST_MICROPHONE = 4001
        private const val STATUS_REFRESH_MS = 500L
    }
}
