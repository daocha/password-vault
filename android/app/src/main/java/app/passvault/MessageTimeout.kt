package app.passvault

import androidx.compose.ui.platform.AccessibilityManager

/** How long the message snackbar stays up before hiding itself (iOS: StatusMessage.displaySeconds). */
const val MESSAGE_MILLIS = 6000L

/**
 * [MESSAGE_MILLIS], or as long as the person's accessibility settings ask. With TalkBack on, the system keeps a message with
 * a button (OK) up until it is pressed, as iOS keeps it while VoiceOver is on.
 */
fun messageTimeoutMillis(accessibility: AccessibilityManager?, error: Boolean): Long =
    accessibility?.calculateRecommendedTimeoutMillis(MESSAGE_MILLIS, containsIcons = error, containsText = true, containsControls = true) ?: MESSAGE_MILLIS
