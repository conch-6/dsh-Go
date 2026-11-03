# Troubleshooting

## Messages won't send, or no reply comes

Check the host status at the bottom of the chat list.

- **This phone**: open the engine page and check its status and **Logs**. Not installed, stopped and failed to start are different cases; follow the page. When a start fails, the failure card links to the logs and a diagnostics bundle.
- **Remote host**: the remote hosts page offers a fix for the cause, such as **Reconnect**, **Sign in again** or **Trust again**.
- If no model is set up, **Choose model** offers to enter an API key or add a provider.

Reset and uninstall both delete data on this phone; you rarely need them to fix a problem.

<!-- nav: commonSettings,phoneEngineDiagnostics -->
`Settings › Diagnostics` · [Open](dshgo://open/diagnostics)

To report a problem, export a diagnostics bundle here. It includes the version, device, logs and the latest crash, never keys or tokens.

To let the AI look into it: tap **Let the AI read diagnostics**. The app writes the same (redacted) snapshot into the engine, then ask the AI to "check the diagnostics" — the bundled `dsh-go-support` skill walks the symptoms and drafts an issue you can paste.

## The engine stops in the background, or notifications don't arrive

<!-- nav: commonSettings,phoneEngineKeepAlive -->
`Settings › Background running` · [Open](dshgo://open/background)

Follow the guide to turn off battery optimization, keep the "engine running" notification, and lock the app in Recents. Limits vary by brand, and Android may still stop the engine.

For notifications, also turn on the alerts you want in the app's **Notifications** and allow DSH Go notifications in system settings. Alerts from remote hosts need the app running and the connection online.

## The engine keeps failing to start

**Automatic Safe mode** on the local engine page is on by default: after two failed starts in a row, the engine starts without plugins. You can also tap **Start in Safe mode** on the same page. Your chats are safe in Safe mode; fix the configuration, then tap **Return to normal mode**. Web settings changed in Safe mode aren't kept.

Direct local engine launch is off by default; you turn it on under Developer options. Once it is on, on a phone where a direct start fails (Android 16 blocks it, for one), it switches to compatible launch on its own: that doesn't count as a failed start and doesn't lead to Safe mode. It keeps using compatible launch until an app update brings a new runtime, and **Diagnostics** shows **Direct launch failed**. To try again, stop the local engine, then turn on **Direct local engine launch** under **Developer options** on the Diagnostics page.

After an upgrade from an earlier version, the first direct start tidies your plugin files once; the engine shows **Tidying plugin files** meanwhile. If the phone is short of space or the tidy-up doesn't finish, that start uses compatible launch, **Fallback reason** on the **Diagnostics** page says why, and the next start carries on. No files are lost.

## Phone control doesn't work

The top of the phone control page says what's missing:

- The switch is off, or the engine hasn't started.
- You're connected to a remote host: switch to **This phone**.
- DSH isn't installed on this phone: install it first.
- Safe mode is on: return to normal mode.
- Accessibility is off: tap **Turn on**. For a sideloaded app, allow restricted settings first.

If a task stopped midway: turning the screen off, locking the phone, or DSH making no new move for 3 minutes ends it. See [Phone control](04-phone-control.md).

## The floating bar is in the way

Tap the dot at the bar's left end (or **Shrink to a ball** in its card) to shrink it to a ball you can drag out of the way, or turn on **Collapse when idle** on the phone control page. The capsule and the ball fade when idle; lower **Idle opacity** to fade them more.

## The pet is gone

- Not in chats: if the pet page is set to **None**, choose a pet; if it's hidden for an hour, tap **Show now**.
- Not outside the app: check that **Show outside the app** is on and display over other apps is allowed. **When to show** defaults to **When active**, which hides the pet after 5 quiet minutes. If it was hidden for today, tap **Restore** on the pet page. It also hides while the app is in the foreground and during phone control tasks.

See [Pets](06-pets.md).

## A plugin is installed but doesn't show up

Check that the plugin is enabled, and restart the engine if asked. A plugin's native UI needs the dsh-go bridge on the host: this phone's engine has it built in, remote hosts usually don't. A display place may also be turned off in the plugin's details. Plugin panels without a native UI appear in the Plugins group of All features, opening in the app or as Web entries. See [Plugins](08-plugins.md).

## What the app sends

<!-- nav: commonSettings,hubPrivacy,usageStatsTitle -->
`Settings › Privacy and sharing › Send anonymous usage stats` · [Open](dshgo://open/usage-stats)

On by default; the switch is on the welcome screen the first time you open the app. If you updated from an earlier version, a one-time notice at the bottom of the home screen tells you, and can turn it off right there. While it's on, the app sends anonymous stats for the days before, at most once a day, and only this: app and Android version, CPU architecture, phone maker (not the model), app language, how the local engine was started, and that day's number of messages, voice inputs, phone control tasks, generations, shares and installed plugins. Devices are told apart by a random ID that changes every 90 days.

Never accounts, API keys, chats, files, prompts or host addresses, and no device identifiers such as phone number or IMEI. Turn it off and nothing more is sent; the random ID and the counts kept on the phone are deleted at once.

## The guide doesn't match what I see

Check the app version under **Version** in Settings and compare it with the version in the [guide index](../README.md). The app is always right.
