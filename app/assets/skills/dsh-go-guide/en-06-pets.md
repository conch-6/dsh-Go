# Pets

Pick a pet to keep you company in chats. When a turn finishes, fails, or waits for your approval or answer, it pops up a bubble. It can also float outside the app.

## Choose a pet

<!-- nav: commonSettings,botsPets -->
`Settings › Pets` · [Open](dshgo://open/pets)

Tap **Pets** in the Appearance group of Settings, or touch and hold the pet in a chat and choose **Pet settings**. Choose a pet first; the other settings appear below it.

- Choose **Deepy**, **Whale girl** or **None**.
- **Size**: **Small**, **Standard** or **Large**. Standard by default.
- **Quiet mode**: animations only, no bubbles.

The pet, size and Quiet mode apply both in and outside the app.

## In chats

- The pet sits above the composer; drag it left or right to move it.
- Tap a bubble to jump to its chat; swipe up to dismiss it.
- Touch and hold the pet for **Change pet**, **Hide for 1 hour** and **Pet settings**. While it's hidden, **Show now** appears on the pet page.

## Show outside the app

1. On the pet page, turn on **Show outside the app** (off by default).
2. Allow "Display over other apps" when asked. If phone control's accessibility service is on, no extra permission is needed. Without permission, the switch turns itself off and shows **Not allowed**.
3. Under **When to show**, choose **When active** (default) or **Always**. When active: shows while a reply is running, a bubble is up, or there was activity in the last 5 minutes.

The floating pet hides while the app is in the foreground and during phone control tasks.

Floating pet: tap to open the chat that needs you most (approvals and questions first); drag it and it snaps to the edge and stays there; drag it onto the × or touch and hold and choose **Hide for today** to hide it for the day. Tap **Restore** on the pet page to bring it back.

On Android 13 and later, if the switch still won't turn on after visiting system settings, **Switch disabled** appears on the pet page. Tap it for brand-specific steps to **Allow restricted settings**.

## Action wheel and screenshot questions

Touch and hold the floating pet without lifting your finger. A half-wheel opens toward the inside of the screen. Slide toward an action to highlight and slightly lift it, then release to choose it. Slide back to the center or outside the wheel before releasing to cancel. The wheel mirrors at the opposite screen edge; tapping and ordinary dragging are unchanged. Accessibility users can also long-press and tap an action directly. Small screens or large fonts use a scrollable list when the wheel will not fit; in that case, release without sliding, then scroll and tap.

Choose **Screenshot & ask DSH-Go** to hide the pet and wheel, capture the current screen and automatically return to the app with the image as a pending attachment in a new chat. Type your question, then tap Send. Nothing is sent to AI automatically, and the previous conversation's draft is not overwritten. Existing text and attachments in the new-chat draft are kept; attachment limits are reported if the image cannot be added.

Capture requires Android 11 or later and phone control's accessibility service to be enabled. Overlay permission alone is not enough. Pages protected against screenshots are not bypassed. The image uses only the app's private temporary cache, which is removed once read into the draft; it is not saved to the gallery. If a phone blocks opening the app from the background, tap the notification to continue.

## Quick ask, bubble decisions and voice

Long-press the floating pet and choose Quick ask to open its input bar. The target line names the conversation and host; switch to a new conversation if needed. Messages go through normal chat and appear in its history. If the host or connection changes, reopen the bar to confirm the target. Back or a tap outside closes the bar.

Approval bubbles show complete tool arguments when a request can be handled there. Missing or lengthy arguments and requests needing detailed interaction open the app instead. Simple single-choice questions can be answered in the bubble. Expired requests cannot be submitted.

The microphone uses the phone's installed offline speech model and does not fall back to a cloud provider. If the model is unavailable, follow the setup guidance. If Android blocks background recording or returns silence, a separate foreground recording dialog brings recognized text back to the input bar. Sending still requires your action, and an existing chat draft is preserved.
