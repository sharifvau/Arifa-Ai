package com.example.arifa

import android.accessibilityservice.AccessibilityService
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

    fun clickSendButton(): Boolean {
        val root = rootInActiveWindow ?: return false
        val targets = listOf("send", "পাঠান", "প্রেরণ", "send button", "Ok", "Permit")
        val node = findClickable(root, targets) ?: return false
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        node.recycle()
        return ok
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
