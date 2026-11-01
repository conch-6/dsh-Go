# Chat

Ask the AI anything, send images and files, and steer or stop it while it works. Chats belong to the current host: switch hosts and the list shows that host's chats.

## Start a new chat

<!-- nav: chatChats,commonNewChat -->
`Chats › New chat`

Tap the menu button at the top left of the chat (or swipe in from the left edge) to open the chat list, then tap **New chat**. There's also a new-chat button at the top right of the chat.

Type your message and tap the send button. The chat is created when you send the first message, so opening a new chat never leaves an empty one behind.

With a hardware keyboard, Enter adds a line break and Ctrl+Enter or ⌘+Enter sends. See Hardware keyboard below for more controls.

## Choose a model

Tap the model capsule at the top right to open **Choose model**. Tap a model to switch right away; if it supports levels, pick one under **Thinking effort**. Typing `/model` in the composer opens it too. **Manage models** at the bottom goes straight to the models page in Settings; to add and manage models, see [Models and providers](02-models.md).

## Images, files and voice

Tap the plus button next to the composer and choose **Photos**, **Take photo** or **File**. You can attach up to 9 items per message. Under **This chat** in the same panel you can change this chat's **Permissions** and turn **Plan mode** on or off; while phone control is on, **Confirmation** is there too.

- On a host connected through DSH Remote, you can send images only.
- If the current model can't view images, they're sent to the AI as files. Switch to a model that can view images to let the AI see them.

When the composer is empty and speech recognition is available, the send button becomes a microphone. Tap it and speak; your words fill the composer so you can check them before sending. When the recognition service isn't available, **Change** on the notice opens the voice input settings.

## Create images and video

When the current host has the image and video plugin, the plus panel has a **Create** tile. Tap it to enter create mode: a capsule above the composer shows the settings, such as "Image · 3:4 · 2 images". Tap the capsule to change the type, model, aspect, number and quality, and for video the length and sound; then describe what you want and send; the settings show under your message. The × on the capsule leaves create mode and keeps what you typed. You can also just ask the AI, "draw a cat napping on the windowsill".

Add reference images from the plus panel as usual. For video, the first image is the **First** frame and the second the **Last** frame.

Created images appear in the chat with a line that says **AI-generated**, the model and the aspect, plus an estimated cost when the price is reliable. Tap an image to view it full screen and swipe through the batch. Under the images you can save to Photos, share or **Regenerate**; More has **Edit**, **Copy prompt** and **Details**. When a description doesn't pass content review, tap **Revise** on the card to get it back in the composer. Videos open in another app for now.

If the host doesn't have the plugin yet, **Create** offers **Install on this host**. Services and API keys are set under Capabilities in [Settings](10-settings.md).

## Commands

Type `/` in the composer for the command list, or `@` to reference a file or another chat. Common commands:

- `/compact`: compact the chat above to free up context.
- `/export`: export this chat's full history as a ZIP to share or save to Downloads.
- `/plan`: enter or leave Plan mode.
- `/goal`: set or view the goal for a long-running task.
- `/permission`: switch the permission preset.
- `/new`, `/model`, `/features`: new chat, choose model, all features.

## Steer or stop the AI while it works

Sending while the AI is replying is a **Steer**: it doesn't interrupt, and the AI sees your message at its next step. Touch and hold the send button to choose a **Send mode**:

- **Steer**: the AI sees it next step, without interrupting
- **Interrupt and send**: stops the current task and handles this first
- **Queue**: sends after this turn

Steered and queued messages appear at the bottom of the chat, where you can **Send now**, **Steer instead** or **Undo**. An undone message goes back to the composer for editing.

While the AI replies with an empty composer, the send button becomes a stop button. Tap it to stop the current turn. Queued messages then start the next turn.

## Answer questions and approvals

Question cards: pick an answer, or tap **Other answer** to write your own, then tap **Submit**. When a single question is waiting, you can also answer in the composer.

Approval cards: check the command, files and reason, then tap **Allow once** or **Decline**.

**Allow for chat** approves everything for the rest of this chat, including requests already waiting. **Auto-approving** appears above the composer; tap it to turn it off. Approvals are asked again after the app restarts. A chat with **Full access** or **Auto review** also shows a capsule above the composer; tap it to change the chat's permissions. To skip approvals in all new chats on this phone's engine, set the new-chat default to **Full access** under Permissions in [Settings](10-settings.md).

## Copy, quote and regenerate

The row under a reply copies, shares, branches and regenerates in one tap. Touch and hold an AI reply for **Copy**, **Select text**, **Quote**, **Share**, **Regenerate** and **Branch here**. Plugins with a native UI add their actions below.

Touch and hold your own message for **Copy**, **Select text** and **Edit and resend**.

**Regenerate**, **Branch here** and **Edit and resend** continue in a new chat and leave the original as is. The notice that appears has **Back to original chat**; after it's gone, the original is still in the chat list.

- **Regenerate** works on the last reply of the chat and resends right away. It's unavailable while the AI replies, while messages are steered or queued, or when the question had files attached.
- **Edit and resend** needs attachments added again.

## Organize the chat list

Touch and hold a chat for **Pin**, **Rename**, **Move to folder**, **Share**, **Select**, **Archive** and **Delete permanently**.

- **Archive** stops a turn in progress. Tap **Undo** on the notice within 4 seconds to keep the chat as it was, turn included; leaving the app archives it at once.
- **Delete permanently** removes the chat record from this host and cannot be undone — unlike archive. The working folder, generated files, branched chats, shared attachments and published cloud shares stay; delete cloud shares separately.
- Deletion asks for confirmation first. A running chat must be stopped; the host also refuses while a chat has subagents, related jobs or reminders. It needs a host that supports it: on an older host the action says so and archive stays the only option — it never falls back to archive silently.
- After selecting several chats, **Delete** in the action bar removes them in one go; failures are listed one by one and only acknowledged chats leave the list. If the connection drops and the result is unconfirmed, the rest of the batch stops — refresh the list before deciding.
- To get an archived chat back, tap **Search chats**, find it and tap **Restore and open**.
- Filter the list with **All**, **Running**, **Pending** and **Unread**. The ⋯ at the end of the workspace row sorts by **Recent activity** or **Date created**, and has **New folder** and **Manage folders**.

## Hardware keyboard

Focus the chat's composer before using these shortcuts:

- Enter: add a line break.
- Ctrl+Enter or ⌘+Enter: send. The numeric keypad's Enter works too. The host must be connected and the draft must contain text or attachments; it won't send while voice input is active.
- While the AI is replying, press Esc twice within half a second to stop the current turn. Holding Esc doesn't count as two presses; one press won't leave the composer.

Send and stop shortcuts don't run while an input method is composing text or choosing a candidate. Finish composing first.

With the `@` reference picker open, ↑ and ↓ select an item, and Enter or Tab inserts it. On a folder, Tab opens the folder instead. Esc closes the picker first; to stop the reply, press Esc twice again after closing it.
