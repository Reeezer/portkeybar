# PortkeyBar

A small native macOS menu bar app showing `12.34$ #2`: your Portkey cost over the selected time range and your spending rank within the API key's workspace. Highest spend ranks first; equal costs share a rank. The app refreshes every five minutes and after wake, and registers to launch at login on first run.

The API key stays in macOS Keychain. Click the menu bar value for manual refresh, settings, the Portkey dashboard, or the login toggle. A warning symbol means the last refresh failed; the menu shows the error and when the displayed value was fetched. A user with no usage has zero cost and ranks below users with positive cost. Requests without a User ID are excluded from the ranking.

Choose **Time range** in the menu for Last 1 hour, Last 5 hours, Last 24 hours, Last 3 days, Last 7 days, Last 14 days, Last 30 days, Today, This week, or This month. The default is Last 24 hours. Your selection is saved across restarts, refreshes immediately, and also applies to `--check`. Today, This week, and This month start at the corresponding boundary in your Mac's calendar and time zone; the other ranges are rolling windows.

## Build and install

Requires Apple Silicon, macOS 14+, and Swift 6 Command Line Tools. No third-party dependencies.

```sh
bash build.sh
mkdir -p ~/Applications
ditto .build/PortkeyBar.app ~/Applications/PortkeyBar.app
~/Applications/PortkeyBar.app/Contents/MacOS/PortkeyBar --configure-from-env
open ~/Applications/PortkeyBar.app
```

`--configure-from-env` reads `PORTKEY_API_KEY` without printing it. Alternatively, enter the key and your Portkey User ID in Settings. The default User ID is your macOS username. Use a workspace key with access to team analytics; an organisation key without a workspace filter would rank its default workspace.

macOS may require approving PortkeyBar under System Settings → General → Login Items. Check the actual API and login registration with:

```sh
~/Applications/PortkeyBar.app/Contents/MacOS/PortkeyBar --check
```

The build runs the usage checks and verifies the local ad hoc signature. It is not notarized for distribution. Quit the app before copying a replacement build. Rebuilds may prompt for Keychain access again because the local signature changes.
