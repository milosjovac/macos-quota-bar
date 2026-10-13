# AI Quota menu bar

A native Swift / AppKit macOS menu bar app for **Codex and Claude** subscription quotas. Shows each tool’s logo, percentage remaining, and reset countdown. Requires macOS 13 or newer.

## Use

Click the menu bar quota to open the standard macOS menu:

- **Detect Installed AI Tools** scans supported app locations and CLI paths. Detection also runs on launch. Currently supports Codex (including the Codex integration in ChatGPT) and Claude Desktop / Claude Code.
- Each detected tool has its own submenu containing usage details and a **Show in Menu Bar** checkbox. Select one, multiple, or none. With none selected, an “AI Quota” item keeps the menu accessible.
- **Show All Selected Quotas** displays the selected tools side by side.
- **Rotate Selected Quotas Every 10 Seconds** cycles through the selected tools, in Codex / Claude order. Rotation does not make additional usage requests.
- **Refresh All** updates usage. **Connect Claude…** allows macOS to request Keychain access when needed.

Selections and display mode persist between launches. Newly detected tools appear in the menu; Codex is selected by default. Missing tools do not appear in rotation, while saved selections are retained for when they are installed again.

The longest quota window is shown in the menu bar, typically weekly. Each tool’s submenu also shows available shorter windows and model-specific limits. Countdown days use one decimal; intervals below a day use hours or minutes. All logos are white, 14 points, and vertically centered with the text.

## Build and run

```sh
./scripts/build.sh --test
open 'build/Codex Quota.app'
```

Builds and ad-hoc signs the app with Xcode or Command Line Tools; no third-party runtime dependencies. The existing app bundle and identifier are retained so upgrades preserve preferences. Copy the app to `/Applications` or `~/Applications` if desired. Add it under System Settings → General → Login Items to launch at login.

## Quota connections

### Codex

Uses the local Codex CLI and its existing ChatGPT sign-in. Run `codex login` if needed. The app initializes a short-lived `codex app-server` and calls [`account/rateLimits/read`](https://learn.chatgpt.com/docs/app-server). It creates no conversations or model requests.

Looks for Codex in Homebrew, `/usr/local/bin`, `~/.local/bin`, PATH, and supported desktop bundles. **Choose Codex CLI…** selects another executable. `CODEX_BINARY` works for command-line launches; a saved selection takes precedence. The CLI’s current account and `CODEX_HOME` determine the quota account.

### Claude

Uses the same `https://api.anthropic.com/api/oauth/usage` endpoint found in the installed Claude Desktop app. This is an internal integration, not a guaranteed public API, and may change in future Claude releases.

For Claude Desktop, reads its encrypted OAuth cache from its app support directory and unlocks it through the **Claude Safe Storage** Keychain item. Only a current inference/profile credential tagged for the desktop app’s last signed-in account is eligible. The desktop decryption key is retained only in memory until this app quits, so one-time Keychain approval covers subsequent refreshes. Tokens are reread from Claude’s encrypted cache for each request, allowing Claude to renew them. No tokens are logged, copied into preferences, or written back; the token is sent only to Anthropic for the usage request. Open Claude’s **Code** tab to create or renew its credential. The quota app does not refresh or alter Claude’s sign-in itself.

When the desktop cache is absent, supports Claude Code’s standard credentials file or **Claude Code-credentials** Keychain item. API-key-only accounts cannot provide subscription quota through this integration.

Automatic checks do not request Keychain dialogs. If access is unavailable, click **Connect Claude…** and allow the macOS prompt. The app then reports connection success or the precise failure. The system may ask again after replacing this locally ad-hoc-signed app with a new build.

## Refresh and failure behavior

Each tool refreshes independently every five minutes and on waking. A failed tool does not hide the other tool. Errors show `— !` in the menu bar, with connection details and clearly marked last known values in the menu. After a reset passes, successful sources retry once a minute until fresh usage arrives; the app does not assume a reset means 100% remaining. Claude HTTP 429 responses pause requests for at least five minutes (or longer when specified by the server). Quota data stays in memory.

## Diagnostics

```sh
'build/Codex Quota.app/Contents/MacOS/CodexQuota' --detect
'build/Codex Quota.app/Contents/MacOS/CodexQuota' --check --all
```

The second command checks every detected tool and reports quota only, never credentials. Without `--all`, it checks Codex only.

## Logo sources

[OpenAI](https://unpkg.com/@lobehub/icons-static-svg@latest/icons/openai.svg) and [Claude](https://unpkg.com/@lobehub/icons-static-svg@latest/icons/claude.svg) SVGs come from LobeHub. Paths are unchanged; dimensions are explicit and fills are white. Logos and trademarks belong to their respective owners. This is an independent utility.
