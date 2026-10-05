# Dock Extend

Native macOS prototype for a dock with configurable side widgets.

## Updates

In DockExtend Settings, choose **Check for Updates…**. If a release is
available, Sparkle shows its release notes and an **Install Update** button.
The app checks only when you ask and installs only after you click the button.
See [CHANGELOG.md](CHANGELOG.md) for release history.

Updates are signed with a Sparkle EdDSA key. To publish a release, update the
version in `AppBundle/Contents/Info.plist` and its notes in `CHANGELOG.md`, then
run `scripts/publish-release.sh <version>` from the authenticated `dorofey`
checkout. The signing key stays in the maintainer's macOS Keychain.

## Multiple docks

Open the plus menu on any dock and choose Customize. The dock selector in
Settings lets you add, duplicate, rename or remove docks and choose a horizontal
or vertical layout. The last dock cannot be removed. Your existing setup becomes
the Main dock.

Drag the dotted grip to move a dock between displays. Positions are saved per
display; Reset position returns the selected dock to its initial location.
Each dock has independent apps, groups, widgets, ordering and backdrop settings.
Integration connections are shared. Long docks scroll along their layout axis,
and detail panels open beside the dock or above/below it to stay on screen.

Multi-dock persistence and panel placement checks:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcrun swiftc Sources/DockExtend/DockProfiles.swift Sources/DockExtend/DockDetailPanel.swift scripts/check-docks.swift -o /private/tmp/dock-profile-check
/private/tmp/dock-profile-check
```

## Run locally

This is a Swift Package executable. Once the full Xcode toolchain is selected:

```sh
swift run
```

To build and launch a normal app bundle:

```sh
./scripts/build-app.sh
open ./DockExtend.app
```

The first vertical slice creates a borderless floating window at the bottom of the main display. The side widgets are compact by default and reveal their details on hover. Use the plus button to switch between compact and always-expanded display modes; the selection is persisted. Launcher tiles open their corresponding macOS applications, and the launcher order is draggable.

## Current toolchain note

The current machine is using `/Library/Developer/CommandLineTools` rather than a full Xcode developer directory. SwiftPM cannot currently build the package because the active Swift compiler and macOS SDK are different builds. After installing Xcode, select it with:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## Slack hover previews

Hover over the Slack launcher for 450 ms to open unread direct-message previews.
Move into the panel to keep it open; leaving the icon and panel dismisses it.
Clicking a message opens its permalink in Slack. Channels, group DMs, and thread
unreads are not included in this first integration.

1. Create an app at https://api.slack.com/apps using the repository's
   `slack-app-manifest.json` (From a manifest).
2. For an existing app, enable **PKCE** in OAuth & Permissions and add redirect
   URL `dockextend-slack://oauth`. Enabling PKCE is a one-way Slack app setting.
3. Copy the public **Client ID** from Basic Information (not the client secret).
4. In DockExtend Settings → Slack previews, enter the Client ID and click
   **Connect with Slack**, then approve access in the browser. Workspace
   administrator approval may be required.

OAuth uses PKCE/S256 and validates a random state; no backend or client secret
is needed. Access and refresh tokens are stored together in Keychain and
automatically rotated before expiry when fetching messages. Slack PKCE refresh
tokens expire after 30 days; reconnect when Slack requests it. The manual user
token field remains available for existing `xoxp-` connections; bot tokens cannot
provide personal unread previews.

Required user scopes are `im:read`, `im:history`, and `users:read`. The token is
stored in macOS Keychain; Disconnect removes it and clears previews. Message
content stays in memory. API requests are sent directly to Slack using an
ephemeral URLSession. No Slack cookies or credentials are extracted from the
installed app.

Previews show up to 30 messages, fetching up to 15 recent unread messages per
DM. Each DM's read marker is checked against message timestamps, excluding your
own messages. Scanning a large DM list can take time; progress appears in the
panel. Refresh is cached for 60 seconds and honors Slack's Retry-After header.
Connection and message retrieval require a live authorized workspace to verify.

## Zed hover projects

Hover over the Zed launcher for 450 ms, or right-click it and choose **Open
projects…**, to list the project groups in Zed's current session sidebar,
including multiple projects sharing a window. Multi-folder groups keep their
folder order. DockExtend reads Zed's local SQLite state without changing it and
uses the bundled Zed CLI to open the selected group's paths. If sidebar state
is unavailable, the panel falls back to existing window titles.
Click an entry to reveal Zed's assigned FlashSpace workspace and switch to the
project. Native Space behavior follows macOS window activation.

Sidebar project listing and CLI switching do not require Accessibility.
Only the fallback window list needs that permission. Its **Open Accessibility
Settings…** button opens System Settings → Privacy & Security → Accessibility.
The list refreshes every five seconds while open.

## Chrome hover tabs

Hover over Chrome for 450 ms, or right-click its launcher and choose **Open
tabs…**. The panel lists tabs from regular Chrome windows with titles and site
names, a total count, and a bottom filter matching titles or URLs. Click a tab
to select that existing tab and bring its window forward; tab IDs are resolved
at click time so reordering tabs does not change the target. Incognito windows
are excluded. The list refreshes every five seconds while open.

Allow DockExtend to control Google Chrome when macOS asks. If denied, enable it
in System Settings → Privacy & Security → Automation and refresh the panel.
No extension or Accessibility permission is needed. Tab metadata stays in
memory; page content is not read.
