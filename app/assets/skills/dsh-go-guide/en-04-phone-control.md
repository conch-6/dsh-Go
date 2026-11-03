# Phone control

Let DSH read the screen, tap and type to get things done on your phone. Pause or stop it anytime. Phone control works only with this phone's engine and isn't loaded in Safe mode.

## Turn it on

<!-- nav: commonSettings,hubSettingsPhoneControl -->
`Settings › Phone control` · [Open](dshgo://open/phone)

1. Turn on the switch at the top. The first time, you'll see what's read and where it goes; tap **Agree**. Turning it on or off restarts a running engine, interrupting any reply in progress.
2. Under **Setup**, tap **Turn on** next to **Accessibility service**, and turn on "DSH Phone Control" in Android's accessibility settings. If the switch won't turn on for a sideloaded app, tap **Accessibility switch disabled?** for brand-specific steps to allow restricted settings.
3. Tap **Turn on** next to **Notifications** and allow notifications in App info. Approvals and the stop button need them.
4. Tap **Read current screen** to see what DSH can read. This reading isn't sent to the model.

During a task, text on the screen is sent to the model you chose; with a vision model, a screenshot may be included. Bank card and ID numbers are masked first.

## Restore accessibility automatically

<!-- nav: commonSettings,hubSettingsPhoneControl,a11yRestoreTitle -->
`Settings › Phone control › Restore accessibility automatically`

Open this row under **Setup**, read the explanation and tap **Authorize and enable**. A connected Shizuku, Sui, root or self-ADB channel can grant permission (the page says which one it will use). If neither is available, follow the setup page or copy the displayed command and run it once on your computer. Restoration requires both the in-app phone-control switch and the system permission.

After granting permission, turning off the accessibility service in Android settings will trigger an attempt to turn it back on. To stop phone control, turn off the switch inside DSH Go. Restoration changes only DSH Go's service entry and preserves other accessibility services.

After a system force-stop, reopen DSH Go before it can recover. Repeated failures back off to about ten minutes between attempts. This permission does not keep the app alive indefinitely or fix the underlying cause of a service crash.

## Ask DSH to do something

Go back to a chat and say what you want done. While a task runs:

- Keep the screen on and unlocked. Turning the screen off stops the task.
- Passwords, verification codes, payments and system settings are up to you (unless you turn them on under Lift limits below). When a step needs you, **Your turn** appears; tap **Continue** when you're done. When one of these rules is the reason, the card's title says so, like **Passwords and codes are yours to enter** or **System settings are yours to change**.
- A task ends on its own when DSH makes no new move for 3 minutes.

Alarms, events, maps and sharing don't need the accessibility service.

## Floating bar

When a task starts, a floating bar appears at the top of the screen. It takes three shapes, and a tap moves between them:

- Capsule (the default): one line saying what DSH is doing, like "Tap “Send”", with **Pause** and **Stop** on the right. After **Pause**, the button reads **Continue**; tap it to let DSH carry on.
- Card: tap the line on the capsule to open it. It shows the app DSH is working in, whether approvals are off, the last few steps, and a field to steer DSH another way. Left alone for a few seconds, it goes back to the capsule.
- Ball: tap the dot at the capsule's left end, or **Shrink to a ball** in the card, to shrink it to a ball at the screen edge. Tap the ball to open it. Drag it anywhere; it snaps to the nearest edge and stays there next time. **Hold the ball for a second to stop**: a ring closes round it first, and letting go cancels.

When DSH needs your approval, the capsule says "Waiting for you below" and the approval card appears at the bottom of the screen.

Adjust it under **Floating bar** on the phone control page (shown once phone control is on):

- **Idle opacity**: how far the capsule or the ball fades after 3 seconds untouched, 30% to 100%, 70% by default. A touch brings it back; the card and anything waiting for you stay solid. With **Collapse when idle** on, the capsule shrinks to a ball instead of fading, and the ball fades.
- **Collapse when idle**: off by default. When on, the capsule shrinks to a ball after a few idle seconds, and opens by itself when you need to approve something.
- **Back to DSH Go when done**: on by default. When the reply ends and the app is in the background, it tries to bring you back to that chat. If the system blocks background windows, use the notification; see Confirmations and return below.

Whatever the settings, the bar closes when the reply ends.

## Stop

- **Stop** on the floating bar, or hold the ball for a second.
- **Stop** on the "Operating your phone" card on the phone control page.
- **Stop actions** on the engine notification. **Stop** on the same notification stops the whole engine.

Stopping phone control also stops every reply in progress on this phone's engine.

## Confirmation

<!-- nav: commonSettings,hubSettingsPhoneControl,phoneConfirmTitle -->
`Settings › Phone control › Confirmation`

- **Always ask** (default): asks before entering a new app, sending, deleting or paying.
- **This task**: asks once per task. Choose **Allow for task** on the approval card, and the rest of the task goes ahead.
- **Always skip**: acts without asking. Asks you to confirm before turning on.

When you pick Phone control during first-time setup, you choose once after agreeing to the disclosure: **Ask me at key steps** (Always ask) or **Fully automatic** (Always skip). You can change it here anytime.

An approval card left for 30 seconds counts as **Decline**. In every mode, system settings and permission pages, passwords and verification codes, and DSH Go itself stay with you unless turned on under **Lift limits**; apps set to Hands off are changed in **App rules**. Confirmation lists these, with links to both.

## Confirmations and return

<!-- nav: commonSettings,hubSettingsPhoneControl,phoneBackgroundGuideTitle -->
`Settings › Phone control › Confirmations and return`

Once phone control is on, this row is under **Advanced** on the phone control page; tap it to read the guidance again. **Open system settings** opens DSH Go's system App info page.

When a step needs your decision, DSH Go shows a card. If the card is unavailable, it tries a notification or returns to the app. Allow phone-control notifications and pop-up alerts in system settings. Some phones also offer a permission to display pop-up windows while running in the background; allowing it can help the app return. Menu names vary by system version.

If the app doesn't return after a task finishes, tap **Task complete · View result** in the notification. If the system blocks notifications or background windows, open DSH Go yourself to see the result. Turning on **Back to DSH Go when done** doesn't guarantee that the system will allow it.

## App rules

<!-- nav: commonSettings,hubSettingsPhoneControl,phoneAppRulesTitle -->
`Settings › Phone control › App rules`

Set each app to **Hands off**, **Every step** or **As usual**. Payment, banking and brokerage apps are **Hands off** by default, and WeChat is **Every step**. Unlisted apps work as usual, and sensitive actions still need approval. Loosening a rule explains the risk first; tap **Change anyway** to apply it. Tap **Add app** to add one by package name.

## Lift limits

<!-- nav: commonSettings,hubSettingsPhoneControl,phoneUnlockTitle -->
`Settings › Phone control › Lift limits` · [Open](dshgo://open/phone-unlocks)

All three are off by default, and each turns on separately:

- **System settings**: permissions, installers, security center, notifications.
- **Passwords and codes**: fill in passwords, verification and payment codes. The action log shows •••• and never what was typed.
- **DSH Go itself**: tap and type inside DSH Go.

Turning one on opens a page first: what AI can then do, what could go wrong, and the disclaimer below. Press and hold **I understand the risks, turn on** for about 1.5 seconds to apply it. Turning one off takes a single tap. Nothing can be turned on while a task is running. While any is on, the Phone control page shows **Limits lifted**, the floating bar puts a small lock before its line, and **Limits lifted** in its card brings you back here. Banking and payment apps aren't here; change them in **App rules**.

Disclaimer:

- Once on, AI can do the above without anyone confirming.
- AI can be misled by content in web pages, messages or files.
- Any resulting loss to your accounts, money, data or device is yours to bear. DSH Go and its developers accept no liability.
- Turn it on only when you need it, and off when you're done.
- We advise against turning it on for a device that holds payment or banking details.

## Action log and advanced

**Recent actions** logs every step, without screen contents. Tap **All actions** to see them. The log lasts until the app closes.

Under **Advanced**:

- **Non-disruptive mode**: works on a hidden screen while you use your phone. Needs Android 14 or later. Pick one under **Channel**: Shizuku if the Shizuku app is installed; Sui if Magisk or KernelSU has the Sui module; Root on a rooted phone (your root manager asks when you tap "Turn on with Root", and su never runs before that); Direct ADB otherwise. Open a channel to see its checklist, finish the setup, then tap "Turn on with …"; the page marks the suggested one but never picks it for you. Shizuku and Direct ADB need Wi-Fi with wireless debugging on, and the screen must still stay on and unlocked. Once it is on, a "Keep … channel" switch sits under "Using …", off by default: with it on, DSH Go reconnects the channel by itself after a disconnect, reopening the app or restarting your phone, so you don't pick it again; with it off, the mode must be reactivated after a restart. "Keep root channel" means DSH Go asks your root manager again by itself, and the manager still decides; Shizuku and Sui only use the permission they already gave and wait for their service, and Direct ADB only uses its existing pairing. An app you force-stopped in system settings doesn't come back on its own after a restart; open DSH Go once.
- **Background running**: prevents Android from turning off accessibility; opens the phone settings guide.
- **Confirmations and return**: see confirmations and task results in time; see Confirmations and return above.
