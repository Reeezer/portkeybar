# PortkeyBar

A tiny macOS menu-bar widget for [Portkey](https://portkey.ai) users who want their spending and team rank at a glance.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)

![The macOS menu bar with PortkeyBar highlighted and a callout showing spending and team rank](menubar-preview.png)

## ✨ Features

- Your spending and workspace rank, always in the menu bar.
- Pick a time range or peek at daily ranking history.
- Native Mac widget; your API key stays in macOS Keychain.

## 📦 Installation

Requires **macOS 14+**, an **Apple Silicon or Intel Mac**, and **Swift 6 Command Line Tools**. Install missing tools with `xcode-select --install`.

```sh
git clone https://github.com/Reeezer/portkeybar.git ~/portkeybar
cd ~/portkeybar
bash build.sh
mkdir -p ~/Applications
ditto .build/PortkeyBar.app ~/Applications/PortkeyBar.app
open ~/Applications/PortkeyBar.app
```

To update, quit PortkeyBar, run `git pull --ff-only` in the source folder, and repeat the build, copy, and open steps.

## 🚀 Usage

Click the widget → **Settings…**, enter your **User ID** and **API key**, then **Save**.

`6.09$ #3` means $6.09 spent in the selected time range, ranked third in your workspace. Highest spend ranks #1; ties share a rank. Friendly rivalry optional.

It refreshes every five minutes and after wake, or with **Refresh now**.

> [!NOTE]
> A ⚠ means the last refresh failed; open the menu for the error.

## ⚙️ Configuration

Set these in **Settings…** or directly in the widget's menu:

| Option | Default | Description |
| --- | --- | --- |
| User ID | Mac username | Exact identifier from Portkey's user analytics. |
| API key | None | Workspace key with analytics access; saved in Keychain. |
| Time range | Last 24 hours | Choose a rolling or calendar range; your choice is saved. |
| Launch at login | On | Toggle it in the menu. |

Connects to Portkey Cloud (`api.portkey.ai`); custom endpoints aren't supported.
