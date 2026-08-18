# Using the ScreenToStream MCP server

ScreenToStream ships a standard **MCP** server, so **any MCP-compatible AI agent** — Claude
Code, Cursor, Zed, a custom client — can browse your recordings and (opt-in) start/stop them.
It's nothing Claude-specific: it speaks plain JSON-RPC over stdio. Reading is always available
and credential-free; recording control is off until you enable it.

## What it exposes

**Read-only (always on):**

| Tool | Arguments | Returns |
|---|---|---|
| `list_recordings` | `query?`, `tag?`, `from?`, `to?` (ISO-8601), `limit?` | newest-first list of `{id, title, created, durationSec, tags, status}` |
| `get_recording` | `id` (required) | full record: `playbackURL`, `hlsURL`, `summary`, `chapters`, `tags`, `status`, `thumbnailPath` |

**Recording control (only when enabled in Settings):**

| Tool | Arguments | Returns |
|---|---|---|
| `start_recording` | `source?` (`display`/`window`), `window?`, `display?` (1-based index for multi-monitor), `resolution?` (`1080p`/`2160p`/`4k`), `camera?`, `camera_position?` (`bottom-right`\|`bottom-left`\|`top-right`\|`top-left`\|`center`\|`left`\|`right`\|`top`\|`bottom`), `camera_size?` (`small`\|`medium`\|`large`), `microphone?`, `system_audio?` | `{accepted, message}` once the countdown begins |
| `stop_recording` | `upload?` (default false) | `{accepted, message, entryId, playbackURL?}` — link when `upload: true` |
| `get_recording_status` | — | `{state}`: idle / countdown / recording / uploading / disabled |

## Setup

The server binary is bundled at `…/ScreenToStream.app/Contents/MacOS/mcp-server`. Point any MCP
client at it over stdio.

**Claude Code (one click):** Settings → **AI agents (MCP)** → **Connect** (runs `claude mcp add`).
Or manually / for any agent, register the stdio command:

```bash
# Claude Code
claude mcp add --transport stdio screen-to-stream "/path/to/ScreenToStream.app/Contents/MacOS/mcp-server"
```

**Claude Desktop:** it uses a JSON config file, not `claude mcp add`. Edit
`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "screen-to-stream": {
      "command": "/path/to/ScreenToStream.app/Contents/MacOS/mcp-server"
    }
  }
}
```

Then **fully quit and reopen** Claude Desktop (⌘Q, not just close the window).

**Any other agent** (Cursor, Zed, custom): add an stdio MCP server entry pointing at the same
binary — the same JSON block works for most clients. Reload MCP servers in your client
afterward. To remove from Claude Code: Settings → **Remove**, or `claude mcp remove screen-to-stream`.

## Example prompts

Browsing (any time):
- "List my ScreenToStream recordings from this week."
- "Find my recording about the login flow and give me its share link."
- "What recordings are tagged `bug`? Show their play.fastpix.com links."

Recording (after you enable control in Settings):
- "Start a 4K screen recording with my camera on."
- "Record the Safari window, no mic."
- "Record my second display with the camera large, top-left."
- "Start recording with a small camera bubble in the center."
- "Stop the recording and upload it — give me the link."
- "Are we recording right now?"

## Recording control — how it stays safe

Recording tools do nothing until you turn on **Settings → AI agents (MCP) → Allow AI agents to
start/stop recordings** (default **off**). The mechanism:

- **Opt-in & visible.** While enabled, an agent's command is dropped as a file into a
  user-only (`0700`) directory the app watches; recording still shows the normal countdown and
  stop pill, and TCC screen-recording permission still applies. Nothing records invisibly.
- **No network surface.** There's no port or URL scheme — writing a command requires the
  ability to run code as you already do. Turn the toggle off and the channel is dead.
- **Bounded.** Commands are versioned, validated, and expire after 10 seconds, so a stale file
  can't fire on launch.

## Privacy

- **Read tools are read-only** and credential-free — the server only reads `history.json`; your
  FastPix token stays in the Keychain. Playback links are already public `play.fastpix.com` URLs.
- **Control is off by default** and, when on, only starts *visible* recordings you can see and
  stop.

## Troubleshooting

- **"Not connected" after clicking Connect** → the `claude` CLI wasn't found. Use *Copy setup
  command* and run it in a terminal where `claude` is on PATH.
- **Server missing after a rebuild** → `./run.sh` writes a fresh `.app`; the binary path is
  stable (`…/ScreenToStream.app/Contents/MacOS/mcp-server`), so a re-Connect isn't usually
  needed. If you moved the app, re-Connect to update the path.
- **Empty list** → you have no recordings yet, or `history.json` doesn't exist
  (`~/Library/Application Support/com.fastpix.screen-to-stream/history.json`).

## For maintainers

The server is the `mcp-server` SwiftPM target; its logic lives in the `MCPCore` library
(Foundation only — it never links AppKit/AVFoundation). Transport is newline-delimited
JSON-RPC 2.0 (`Sources/MCPCore/JSONRPC.swift`); tools are in `Tools.swift`; the read model
mirrors the app's `HistoryEntry` in `Recording.swift`. Golden-transcript and unit tests are in
`Tests/MCPTests`.
