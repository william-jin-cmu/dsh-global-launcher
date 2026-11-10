# dsh-global-launcher

A global hotkey that opens a small prompt bar from anywhere on your Mac and sends what you type to DeepSeek Harness.

macOS only.

## Use

| Key | What happens |
| --- | --- |
| `⇧⌘Space` | Opens the bar |
| `⌥⌘Space` | Goes straight to the screenshot picker, then opens the bar with the picture attached |
| `Return` | Sends. The bar leaves at once; it only comes back if the send failed |
| `Shift+Return` | New line |
| `Tab` | Switches between a new session and the last one |
| `⌘1` | Attaches or removes a screenshot of the whole screen |
| `⌘2` | Attaches or removes the text of the window you were in |
| `Esc` | Closes the bar |

The foot of the bar chooses where the prompt goes:

- **New / Last**: start a session, or continue the most recent one.
- **Workspace** and **model**: used for a new session. With [dsh-native-runtimes](https://github.com/william-jin-cmu/dsh-native-runtimes) installed, Claude Code and Codex are in the model list.
- **Create more**: the bar stays open after a send, ready for the next prompt.
- **Open DSH**: bring DSH forward and show the session after a send. Off keeps you in the app you were in.

These choices are remembered in `$DSH_HOME/global-launcher/state.json`.

## Install

Requires DSH `>=0.2.1-rc.5 <0.3.0` and Node.js 22.19 or later.

```sh
dsh plugin --profile web add ./dsh-global-launcher-0.1.0.tgz
```

In the desktop app, use Plugins > Add plugin with the path of the tarball instead.

The hotkeys work while DSH is running. macOS asks for **Screen Recording** (screenshots) and **Accessibility** (window text) for the app DSH runs in. By default macOS binds `⌥⌘Space` to "Show Finder search window": turn that off in System Settings > Keyboard > Keyboard Shortcuts > Spotlight, or change `contextHotkey`.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `hotkey` | `shift+cmd+space` | Opens the bar |
| `contextHotkey` | `option+cmd+space` | Screenshot first, then the bar. Empty turns it off |
| `contextChars` | `6000` | How much window text is attached at most |
| `excludeApps` | Password managers | Bundle ids whose windows are never attached |
| `workspace` | empty | Folder used for new sessions until you pick one in the bar. Empty uses the most recent workspace |
| `desktopApps` | `com.deepseek.harness` | Bundle id prefixes of DSH desktop apps, brought forward after a send |

A model that takes no images gets the prompt without the screenshot.

## Scripting

`POST /api/global-launcher/launch` with `{ text, screenshot?, context?, pid?, target?, workspaceId?, model?, openMain? }` submits a prompt as if it had been typed into the bar.

## Build

```sh
pnpm install
pnpm run pack   # dist/, bin/ and dsh-global-launcher-0.1.0.tgz
```
