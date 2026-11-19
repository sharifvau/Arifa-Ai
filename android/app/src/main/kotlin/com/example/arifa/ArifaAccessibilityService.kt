package com.example.arifa

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Best-effort UI automation: taps WiFi switch / WhatsApp Send button.
 * Android restricts apps from toggling WiFi directly, so we navigate the
 * Settings UI. OEM screens differ; this is intentionally defensive.
 */
class ArifaAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: ArifaAccessibilityService? = null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    /** Types a reply into WhatsApp's composer and taps Send. */
    fun typeAndSend(text: String): Boolean {
        if (text.isEmpty()) return false
        val root = rootInActiveWindow ?: return false
        val input = findEditable(root) ?: return false
        var typed = false
        try {
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    text,
                )
            }
            typed = input.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            if (!typed) {
                val clipboard = applicationContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("arifa_reply", text))
                typed = input.performAction(AccessibilityNodeInfo.ACTION_PASTE)
            }
        } catch (_: Exception) {
            typed = false
        } finally {
            try { input.recycle() } catch (_: Exception) {}
        }
        if (!typed) return false
        return clickSendButton()
    }

    fun clickSendButton(): Boolean {
        val root = rootInActiveWindow ?: return false
        val targets = listOf(
            "send", "send button", "পাঠান", "প্রেরণ", "Ok", "Permit",
        )
        val node = findClickable(root, targets) ?: return false
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        node.recycle()
        return ok
    }

    private fun findEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val cls = node.className?.toString().orEmpty()
        if ((cls.contains("EditText") || node.isEditable) && node.isEnabled) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findEditable(child)
            if (found != null) return found
            try { child.recycle() } catch (_: Exception) {}
        }
        return null
    }

    fun tapWifiSwitch(): Boolean {
        val root = rootInActiveWindow ?: return false
        val targets = listOf("wi-fi", "wifi", "ওয়াইফাই", "ওয়াইফাই", "Switch", "Toggle")
        val node = findClickable(root, targets) ?: return false
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        node.recycle()
        return ok
    }

    private fun findClickable(
        node: AccessibilityNodeInfo,
        targets: List<String>,
    ): AccessibilityNodeInfo? {
        val text = listOf(node.text, node.contentDescription)
            .map { it?.toString().orEmpty() }
            .joinToString(" ")
            .lowercase()
        val matches = targets.any { text.contains(it.lowercase()) }
        if (matches && node.isClickable && node.isEnabled) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findClickable(child, targets)
            if (found != null) return found
            child.recycle()
        }
        return null
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }
}
