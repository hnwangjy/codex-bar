# Codex Bar

English | [简体中文](README.md)

<p align="center">
  <img src="codex_bar/Assets.xcassets/AppIcon.appiconset/icon-256.png" width="128" alt="Codex Bar icon">
</p>

Codex Bar is a lightweight native macOS utility for viewing your remaining 5-hour and weekly Codex usage directly from the menu bar.

On launch, the app first displays a connection panel where you can confirm the local Codex login status and usage data. Select **Start Menu Bar** to keep the remaining percentage visible in the menu bar. The panel and settings remain accessible even when a connection fails.

## Features

- Shows remaining 5-hour and weekly usage, reset times, and plan type
- Lets you display 5-hour usage, weekly usage, or both in the menu bar
- Automatically follows the macOS system language in English or Simplified Chinese
- Provides a startup panel with connection status and retry controls
- Reads the Codex login file from `~/.codex/auth.json` by default, with support for selecting another file
- Supports automatic refresh every 5, 15, or 30 minutes
- Detects usage resets and offers separate system notifications for 5-hour and weekly resets
- Stores preferences locally in `UserDefaults`
- Never stores or displays login tokens

Reset notifications compare two consecutive successful refreshes. A notification is sent when remaining usage rises significantly, or when usage rises after crossing the previously scheduled reset time. The initial load only establishes a baseline and does not send a notification. Weekly notifications have no fixed cooldown: each continuous increase is reported once, and the detector rearms after usage decreases, allowing it to detect an unscheduled official reset. The 5-hour notification is disabled by default, while the weekly notification is enabled by default. A test notification is available in Settings.

## Requirements

- macOS 13 or later
- Xcode 15 or later
- A valid local Codex login file created by Codex CLI or Codex

## Build and Run

1. Clone the repository:

   ```bash
   git clone https://github.com/hnwangjy/codex-bar.git
   cd codex-bar
   ```

2. Open `codex_bar.xcodeproj` in Xcode.
3. Select the `codex_bar` scheme and **My Mac**, then click Run.
4. Confirm the connection in the startup panel and select **Start Menu Bar**.

If the app cannot find login information, run:

```bash
codex login
```

Then return to the app and select **Reconnect** or **Test Connection**.

## Privacy and API Notice

Codex Bar only reads the local Codex login file and sends its access token as an Authorization header to the usage endpoint on the official ChatGPT domain. The app contains no telemetry or proxy service and does not store the token in its own preferences.

The usage endpoint is not currently a public or stable developer API. Its address or response structure may change. This project is not affiliated with or officially endorsed by OpenAI.

## Build a Distribution DMG

Public distribution requires a valid `Developer ID Application` certificate and Apple notarization. A development certificate or unsigned build is not sufficient.

1. Create a `Developer ID Application` certificate in Xcode under **Settings → Accounts → Manage Certificates**.
2. Store notarization credentials in the keychain (the command securely prompts for an app-specific Apple ID password):

   ```bash
   xcrun notarytool store-credentials codex-bar-notary \
     --apple-id "your Apple ID" \
     --team-id 64XC9BXK5K
   ```

3. Build, sign, notarize, and create the DMG:

   ```bash
   NOTARY_PROFILE=codex-bar-notary scripts/build-dmg.sh 0.0.3
   ```

4. Push the version tag and publish the DMG to GitHub Releases:

   ```bash
   git tag v0.0.3
   git push origin v0.0.3
   scripts/publish-release.sh 0.0.3
   ```

The final file is written to `dist/Codex-Bar-0.0.3.dmg` and contains `Codex Bar.app` with an Applications shortcut.

## Automatic Updates

Codex Bar uses Sparkle to check and install updates from the repository's `appcast.xml`. It checks automatically once per day by default, and users can also choose “Check for Updates” from Settings or the menu popover.

For future releases, update the appcast before creating the tag:

```bash
scripts/update-appcast.sh 0.0.4 4
```

The Sparkle EdDSA private key remains in the publisher's macOS Keychain and must never be committed. Users must manually install the first release that includes the updater; subsequent releases can update in place.

## Source and Acknowledgements

The approach used to read Codex authentication data, discover the usage endpoint, and route usage windows is derived from [CodexIsland by Eric Park](https://github.com/ericjypark/codex-island), which is distributed under the [MIT License](https://github.com/ericjypark/codex-island/blob/main/LICENSE).

This project reimplements the experience as a SwiftUI menu bar utility with a startup panel, settings, connection handling, and reset notifications. The upstream copyright notice and permission text are retained in accordance with the MIT License.

## License

This project is distributed under the [MIT License](LICENSE). Portions derived from CodexIsland retain the original author's copyright notice.
