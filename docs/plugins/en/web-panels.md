# Opening web plugin panels

Web plugins that register `sidebar.panellist` + `main` remain available in **All features › Plugins**.

Chat details now provides another entry: when the current host has no visible conversation-specific plugin tabs (`sidebar.right.pane.tab`), its **Plugins** tab shows `main` panels. A single panel opens directly; several panels appear as a list first. Existing conversation-specific tabs retain priority, with global panels still available in All features.

Global panels keep their root scope and receive no current `sessionId`. The existing planner still chooses a native panel, web island or **Open in web** entry within each slot. This entry grants native panels no additional invoke permissions. An empty plan produces no tab.

The panel name comes from its `main` label, then the same plugin and cell in `sidebar.panellist`, then the plugin name. Give sidebar entries short, clear names that no other panel uses: the app finds the panel by that name in DSH Web's sidebar, and when two go by it, it doesn't guess and offers **Open in DSH Web** instead. The same goes for a plugin's settings section (`settings.section`).

## Conversation views

A plugin that registers a View of a conversation in DSH Web (`conversation.view`, another way to look at it beside Chat and Trajectory) shows in the app under that conversation's Chat details › **Plugins** tab, with the conversation's plugin tabs: tabs first, then views. A single one opens directly; several appear as a list first.

- Its name is the registered `label`. The app finds the view by that name in DSH Web's View tab row (or under **More conversation views**), then checks by the view's id that it opened that one, so give it a short name of its own: when another view goes by the same name, the app doesn't guess and offers **Open in DSH Web** instead.
- A page island, only on this phone's own engine, with the bridge's occupancy table, the route guard on and room in the budget; it shows the loading skeleton first, and not on screen within 12 s, it becomes **Open in web**, into this conversation.
- The app picks the View only inside the island and leaves the View the person chose in DSH Web as it was: the island writes their choice back once it shows, and again on the way out.
- The official Chat and Trajectory do not show here.

## The chat page's Plugins sheet

The last capsule above the chat page's composer, **Plugins** (a puzzle icon), opens the conversation's plugin sheet. It shows only while the sheet has something, outside the eight capsules, and steps aside with the row while a reply is generating.

To hide this app-owned entry, add `pluginCapsule` to the existing `hide` array in `$DSH_HOME/dsh-go/ui.json`, for example `{"version":1,"hide":["pluginCapsule"]}`. Remove it, or restore that setting to its default in the app, to show the entry again. This does not disable plugins, hide their own composer actions, or remove panels from All features / Chat details. The `plugins.seats` map configures plugin slots; `chat.panel` and `dsh-go.panel` do not name this built-in capsule.

The sheet holds the native panels first (`placement: "chat.panel"`, by plugin name), then the web plugins' chat-page parts: the third-party entries of these seven slots — `conversation.session.header.actions`, `conversation.session.header.utilities`, `conversation.input.dock`, `conversation.input.left`, `conversation.input.right`, `conversation.input.overlay`, `conversation.composer.dock`. They share **one** panel island, stacked in page order, with the official entries masked; a line above it says whose they are.

- The island is made when the sheet opens and goes 30 s after it closes, so the chat page stays light.
- It is made only when every part could be an island on its own (this phone's engine, the bridge's occupancy, the route guard), none was set to `web` or hidden in `ui.json`, and the budget has room; otherwise, or when it is not on screen within 8 s, or the page cannot find the slots, it is one **Open in web** row.
- Entries inside the island carry no marks of their own, so the app cannot hide one plugin's; a `ui.json` setting on any of them sends the whole part to the web.

## Plugin details: Web parts

A plugin's details list where its web part sits in places the app has no seat for (beside the composer, in messages, a global overlay…), one row per place, each opening DSH Web. Conversation views and chat-page parts have seats now (above) and are not listed. A host without the occupancy table shows one row saying the plugin has a web part.

## Hosts and fallback

- Islands still require a host with web pages, the existing route gate and available resource budget.
- If an island cannot open, the existing DSH Web entry opens the sidebar so the person can choose the panel. The web opening bridge has no third-party panel deep-link id, so it cannot promise to land on an arbitrary plugin cell.
- Relay hosts without web pages do not show web-only panels.

## Not yet available

This entry adds no `plugin:` page references to `ui.json`, cross-plugin `open` aliases or `dsh-go://panel/…` deep links. Native `open` effects still target supported app pages or the calling plugin's `panel:<id>`. Additional targets need separately defined validation, lifecycle and permission boundaries.
