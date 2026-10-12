# PortkeyBar

Your Portkey spending and team spending rank in the macOS menu bar. For example, `12.34$ #2` means $12.34 spent in the selected time range, ranked second in your workspace. Highest spend ranks #1; equal costs share a rank.

## Install

Requires an Apple Silicon Mac, macOS 14 or later, and Swift 6 Command Line Tools. If you need the tools, run `xcode-select --install` and finish the installer first.

Open Terminal and run:

```sh
git clone https://github.com/Reeezer/portkeybar.git ~/portkeybar
cd ~/portkeybar
bash build.sh
mkdir -p ~/Applications
ditto .build/PortkeyBar.app ~/Applications/PortkeyBar.app
open ~/Applications/PortkeyBar.app
```

Click PortkeyBar's text in the menu bar, choose **Settings…**, and enter your Portkey User ID and a workspace API key with analytics access. Your API key is saved in macOS Keychain.

## Use

- **Time range** lets you choose the last 1h, 5h, 24h, 3d, 7d, 14d, or 30d, plus Today, This week, and This month. Last 24 hours is the default; your selection is saved across restarts.
- Today, This week, and This month use your Mac's calendar and time zone. The other ranges are rolling windows.
- Spending refreshes every five minutes and after wake. Choose **Refresh now** for an immediate update.
- **Launch at login** is enabled by default. Toggle it in the menu; approve it in System Settings → General → Login Items if macOS asks.
- A **⚠** means the last refresh failed. Open the menu to see the error and when the displayed value was fetched.

## Update

Choose **Quit PortkeyBar** in the menu, then run:

```sh
cd ~/portkeybar
git pull --ff-only
bash build.sh
ditto .build/PortkeyBar.app ~/Applications/PortkeyBar.app
open ~/Applications/PortkeyBar.app
```

Updating keeps your saved API key, User ID, and time range. macOS may ask you to allow Keychain access again. If you cloned the source somewhere other than `~/portkeybar`, use that folder instead.

## Remove

1. Turn off **Launch at login** if it is checked, then choose **Quit PortkeyBar**.
2. In Finder, move `~/Applications/PortkeyBar.app` to the Trash. If PortkeyBar still appears in System Settings → General → Login Items, remove it there too.

To also delete the saved API key and settings, run:

```sh
security delete-generic-password -s local.portkeybar.usage -a analytics
defaults delete local.portkeybar.usage
```

You can also move `~/portkeybar` to the Trash to remove the source and local builds.
