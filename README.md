# ScreenToStream

A native macOS menu-bar screen recorder that uploads straight to [FastPix](https://fastpix.io)
and hands you a shareable `play.fastpix.com` link in seconds. It also ships an **MCP server**, so
any AI agent — Claude Code, Claude Desktop, Cursor, Zed — can browse your recordings and start and stop them for you.

- Record any display or window at up to 4K, with an optional circular camera PiP, system audio and microphone
- Review, trim, then upload to **your own** FastPix account
- Local library that tracks what's uploaded and what isn't
- Read-only + action MCP tools for AI agents

**Requirements:** macOS 14 (Sonoma) or later, Swift 5.10+ (Xcode 15+ toolchain).

---

## Quick start

```bash
git clone <repo-url> screen-to-stream
cd screen-to-stream
./run.sh
```

`run.sh` builds both binaries, assembles `ScreenToStream.app`, signs it, launches it, and tails
the log. Look for the record icon in your menu bar.

On first launch, grant **Screen Recording** (and Camera/Microphone if you want them) in
System Settings → Privacy & Security. See [Code signing](#code-signing) for why an unsigned build
re-asks after every rebuild.

### Using Xcode

```bash
open Package.swift
```

Xcode handles signing automatically with your Apple ID. Select the **App** scheme and run — the
Info.plist is embedded in the binary, so permission prompts work correctly from Xcode too. The
**mcp-server** scheme builds the MCP binary.

### Using swift build directly

```bash
swift build                          # build the app binary
swift build --product mcp-server     # build the MCP server
swift test                           # run the test suite
```

`swift build` compiles the binaries but doesn't create the `.app` bundle that macOS needs for
permissions and for the MCP server to be found. Use `./run.sh` or Xcode for a complete build.

---

## Setting up FastPix

1. Grab an **Access Token ID** and **Secret Key** from your FastPix dashboard. Use a dev/sandbox
   token, and revoke it from the dashboard when you're done.
2. Open the app → menu-bar icon → **Settings** → paste both → **Save** → **Test connection**.

Credentials are stored in the macOS Keychain and never written to logs, preferences, or the
library file. "Clear" removes them.

---

## Recording

1. **Pick a source** — a display or a specific window (searchable, with live thumbnails).
2. **Optional camera** — pick a camera and a draggable circular preview appears. Where you drop
   it is where it lands in the video, and you can keep dragging it while recording.
3. **Audio** — system audio and microphone toggles, both on by default.
4. **Start** — 3-2-1 countdown, then a floating stop pill with the elapsed timer.
5. **Review** — play it back, scrub, ±10 s, full-screen preview, and trim with the head/tail
   handles.
6. **Save** to the library, or **Upload** — progress, then processing, then the link is on your
   clipboard.

Recordings are written to `~/Movies/ScreenToStream/`.

### Library

Everything you record shows up in the Library (menu-bar icon → Library), whether or not you
uploaded it:

| State | Actions |
|---|---|
| Local only | Upload · Remove |
| Uploading / processing | inline progress · Cancel |
| Uploaded | Copy Link · Open · Remove · Delete from FastPix |
| Failed | Retry · Remove |

**Remove** takes the item out of your local library (and deletes the local file); the FastPix
asset and its share link keep working. **Delete from FastPix** is the irreversible one — it
deletes the remote asset and breaks the link, so it asks for confirmation.

### Settings

- **FastPix credentials** — token, secret, test connection
- **Recording** — keep the local file after upload, recordings folder, upload resolution (1080p / 4K),
  and **Show Dock icon** (adds a Dock icon + Cmd-Tab entry — useful when a full menu bar hides the status icon)
- **AI & subtitles** — request subtitles and chapters at upload. These are fire-and-forget: the
  app asks FastPix to generate them and never waits, so your link is never delayed. Results show
  up in the FastPix dashboard, not in the app. Chapters need an AI-enabled FastPix account.
- **AI agents (MCP)** — connect the MCP server and, optionally, let agents control recording

---

## AI agents (MCP)

The app bundles a standard MCP server at
`ScreenToStream.app/Contents/MacOS/mcp-server`. Any MCP-compatible client can use it.

**Claude Code** — Settings → AI agents (MCP) → **Connect** (or `claude mcp add --transport stdio
screen-to-stream "/path/to/ScreenToStream.app/Contents/MacOS/mcp-server"`).

**Claude Desktop** — edit `~/Library/Application Support/Claude/claude_desktop_config.json`, then
fully quit and reopen Claude Desktop (⌘Q — closing the window isn't enough):

```json
{
  "mcpServers": {
    "screen-to-stream": {
      "command": "/path/to/ScreenToStream.app/Contents/MacOS/mcp-server"
    }
  }
}
```

**Cursor / Zed / anything else** — same stdio command, in that client's MCP config.

### Tools

| Tool | What it does |
|---|---|
| `list_recordings` | List recordings; filter by `query`, `tag`, `from`/`to`, `limit` |
| `get_recording` | One recording's details: playback URL, HLS URL, duration, chapters, thumbnail |
| `start_recording` | Start recording (see options below) |
| `stop_recording` | Stop; `upload: true` uploads and returns the share link |
| `get_recording_status` | idle / countdown / recording / uploading / disabled |

`start_recording` options: `source` (`display`/`window`), `window` (fuzzy title match),
`display` (1-based monitor index), `resolution` (`1080p`/`2160p`/`4k`), `camera`,
`camera_position` (`bottom-right`, `bottom-left`, `top-right`, `top-left`, `center`, `left`,
`right`, `top`, `bottom`), `camera_size` (`small`/`medium`/`large`), `microphone`, `system_audio`.

Try: *"Record my second display in 4K with a large camera in the top-left, no mic"* → *"stop and
upload it, give me the link"*.

### Letting agents control recording

Reading your library works out of the box. **Starting and stopping recordings is off by default**
— turn on *Settings → AI agents (MCP) → Allow AI agents to start/stop recordings*.

How that stays safe: commands travel as files in a `0700` user-only directory the app watches —
there's no network port and no URL scheme, so writing one requires already being able to run code
as you. Recording started this way still shows the countdown and the stop pill, and screen-recording
permission still applies, so nothing records invisibly. Commands expire after 10 seconds, and
turning the toggle off kills the channel.

Full guide, including troubleshooting: [docs/mcp-usage.md](docs/mcp-usage.md).

> **After every rebuild**, restart your MCP client. Clients spawn the server once and keep that
> process for the session, so a rebuilt binary isn't picked up until the client restarts.

---

## Code signing

macOS wants a signed `.app` bundle for screen recording, camera and microphone access. The build
scripts handle it automatically:

| You have | What happens | Permissions persist across rebuilds? |
|---|---|---|
| Apple Developer Program membership | Signs with your Developer ID or Apple Development certificate | Yes |
| Free Apple ID added to Xcode | Signs with your development certificate | Yes |
| Nothing | Falls back to ad-hoc signing | No — you'll re-grant permissions each rebuild |

To get persistent permissions without a paid developer account:

1. Open Xcode → Settings → Accounts and sign in with your Apple ID
2. That creates a free development certificate on your machine
3. `run.sh` finds and uses it automatically

You can also name an identity explicitly:

```bash
./run.sh --identity "Apple Development: you@example.com"
# or
SIGN_IDENTITY="Apple Development: you@example.com" ./run.sh
```

---

## Distributing the app

**Building the artifacts:**

```bash
./release.sh                  # dist/ScreenToStream-<version>.zip and .dmg
./release.sh --notarize       # additionally notarize and staple (needs a Developer ID)
```

What actually happens when someone else opens your build depends entirely on how it's signed:

| Signed with | On your Mac | On someone else's Mac |
|---|---|---|
| Ad-hoc | Runs | **Blocked** — "unidentified developer"; needs right-click → Open |
| Free Apple Development certificate | Runs | **Still blocked** — development certs aren't valid for distribution |
| **Developer ID + notarization** | Runs | **Opens normally** |

So for friction-free distribution to arbitrary Macs you need the **Apple Developer Program**
($99/yr) → a *Developer ID Application* certificate → notarization. There's no free path around
Gatekeeper; that's deliberate on Apple's part. `release.sh` prints an honest `spctl` verdict so
you always know which case you're shipping.

**Notarizing** (once you have a Developer ID):

```bash
# one-time: store credentials in the keychain
xcrun notarytool store-credentials fastpix-notary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

NOTARY_PROFILE=fastpix-notary ./release.sh --notarize \
  --identity "Developer ID Application: FastPix (TEAMID)"
```

CI can do it too — set `SIGNING_CERTIFICATE_P12`, `SIGNING_CERTIFICATE_PASSWORD`,
`SIGNING_IDENTITY`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_APP_PASSWORD` as repository
secrets and push a tag. Without those secrets the release workflow still succeeds, producing an
unnotarized (tester-only) build rather than failing.

**Sending a build to a tester without notarization** — tell them to right-click the app → **Open**
→ **Open**, or:

```bash
xattr -dr com.apple.quarantine /path/to/ScreenToStream.app
```

`dist/README.txt` ships alongside the artifacts with these instructions.

---

## Troubleshooting

**Permissions are asked for again after every rebuild** — expected with ad-hoc signing; the
signature changes each build so macOS treats it as a new app. Add a free Apple ID certificate
(see [Code signing](#code-signing)), or run `./run.sh --reset-tcc` for a clean slate.

**Recording takes ~10-15 s to start** — that's ScreenCaptureKit warming up before the countdown,
deliberately done up front so the recording itself starts instantly.

**An MCP client says the tool failed or hangs** — restart the client after a rebuild (see the note
above). Check *Settings → AI agents (MCP)* shows Connected, and that the control toggle is on if
you're trying to start recordings.

**Nothing happens when an agent tries to record** — screen-recording permission may have been
reset by a rebuild. Open the app and start a recording manually once to re-grant.

**The menu-bar icon is gone / I can't reopen the window** — macOS hides status icons when the
menu bar overflows (common on notch Macs), and there's no API to force one to stay. Turn on
*Settings → Recording → Show Dock icon* for an always-reachable Dock icon and Cmd-Tab entry;
relaunching the app (Spotlight, or `open -a ScreenToStream`) also just reopens the window.

**A full-screen app doesn't appear under Windows** — set
`defaults write com.fastpix.screen-to-stream FPDumpWindows -bool YES`, reopen the picker, and check
`app.log` for the raw window list (layer/on-screen/size per window) to see why it was filtered.

**Where are the logs?** `~/Library/Logs/ScreenToStream/app.log` (Settings → Reveal log).
Credentials are scrubbed before anything is written.

---

## Development

```
Sources/App/          the menu-bar app (capture, upload, library, control channel)
Sources/MCPCore/      MCP protocol, tools, history reader  (Foundation only)
Sources/MCP/          the mcp-server executable
Tests/                AppTests + MCPTests
scripts/assemble.sh   build + bundle + sign (shared by run.sh and release.sh)
docs/                 MCP usage guide
```

```bash
swift test                                       # full suite
FP_LIVE=1 FP_TOKEN_ID=… FP_SECRET=… \
  swift test --filter LiveUploadIntegrationTests # real end-to-end upload (skipped by default)
```

The MCP integration guide is in [docs/mcp-usage.md](docs/mcp-usage.md).

## License

MIT — see [LICENSE](LICENSE).
