# MCP Server Guide

Bar Tasker includes an embedded MCP stdio server so an AI assistant can work directly with your Checkvist data.

- Server command: `Bar Tasker --mcp-server`
- Transport: stdio, newline-delimited JSON — one JSON-RPC object per line, as the
  MCP stdio transport specifies. LSP-style `Content-Length` framing is also
  accepted, and replies mirror whichever framing the client used.
- Dependencies:
  - Installed app: none beyond Bar Tasker itself
  - Local debug/dev flow: `python3` can be used as an automatic fallback runner

## What It Can Do

The server exposes these MCP tools:

- `checkvist_list_lists`
- `checkvist_fetch_tasks`
- `checkvist_quick_add_task`
- `checkvist_update_task`
- `checkvist_complete_task`
- `checkvist_reopen_task`
- `checkvist_invalidate_task`
- `checkvist_delete_task`

Notes:

- It talks directly to the Checkvist API.
- It does not automate the local macOS app UI.
- `quick_add` supports both root insertion and specific parent insertion.

## Setup (the short version)

**Preferences → Plugins → Native MCP Integration.** Enable the toggle and the page
walks three steps:

1. **Checkvist connected** — the server signs in with your Checkvist credentials,
   so setup is blocked until they exist. Without them the generated config carries
   `you@example.com` placeholders and every tool call fails inside your AI client,
   a long way from the app.
2. **Server command found** — the path to the executable an MCP client launches.
   Press Refresh after moving the app.
3. **Add to an AI client** — one button per client detected on this machine.

Bar Tasker detects Claude Code, Claude Desktop, Cursor, Windsurf, VS Code, and
Zed. What the button does depends on the client, because the wrong route is worse
than no route:

| Client | Action | Why |
|---|---|---|
| Claude Desktop, Cursor, Windsurf, VS Code | Writes the config file | Plain JSON files that hold nothing but MCP config |
| Claude Code | Copies a `claude mcp add-json` command to run | Claude Code rewrites `~/.claude.json` constantly; editing it underneath would race |
| Zed | Copies a snippet to paste | `settings.json` carries comments that a JSON rewrite would delete |

Direct writes **merge**: your other MCP servers and every unrelated key survive.
If the existing file isn't valid JSON, Bar Tasker refuses rather than replacing
it. Keys come back sorted, so expect the file to be reformatted once.

Release builds are sandboxed, so the first write to a client's config asks for
access to that folder through an open panel (already pointed at the right place).
The grant is remembered per client, so credential changes re-install silently.

If nothing is detected, use **Copy Client Config** and paste it in by hand — the
rest of this guide covers that.

## Configuration

Set these environment variables for the MCP process (in your MCP client config):

- `CHECKVIST_USERNAME` (required)
- `CHECKVIST_REMOTE_KEY` (required)
- `CHECKVIST_LIST_ID` (optional default list)
- `CHECKVIST_BASE_URL` (optional, defaults to `https://checkvist.com`)

If `CHECKVIST_LIST_ID` is not set, pass `list_id` in tool calls that need a list.

Command resolution priority used by the built-in MCP plugin:

1. `BAR_TASKER_MCP_EXECUTABLE_PATH` (explicit app executable override)
2. App executable candidates (`Bundle.main`, `/Applications/Bar Tasker.app/...`)
3. Bundled fallback script (`scripts/bar_tasker_mcp_server.py`) via `python3`

Extra control env vars:

- `BAR_TASKER_MCP_SCRIPT_PATH` to point at a specific fallback script path
- `BAR_TASKER_MCP_PREFER_SCRIPT=1` to force script mode
- `BAR_TASKER_MCP_PREFER_APP=1` to force app mode
- `BAR_TASKER_MCP_GUIDE_PATH` to override guide detection

## Run Manually

```bash
CHECKVIST_USERNAME="you@example.com" \
CHECKVIST_REMOTE_KEY="your-remote-key" \
CHECKVIST_LIST_ID="123456" \
'/Applications/Bar Tasker.app/Contents/MacOS/Bar Tasker' --mcp-server
```

It will wait for an MCP client to connect over stdio.

## Client Config Example

Most MCP clients accept a JSON config similar to this:

```json
{
  "mcpServers": {
    "bar-tasker": {
      "command": "/Applications/Bar Tasker.app/Contents/MacOS/Bar Tasker",
      "args": ["--mcp-server"],
      "env": {
        "CHECKVIST_USERNAME": "you@example.com",
        "CHECKVIST_REMOTE_KEY": "your-remote-key",
        "CHECKVIST_LIST_ID": "123456"
      }
    }
  }
}
```

Use your own app path and credentials.

If the generated config uses script fallback, it will look like:

```json
{
  "mcpServers": {
    "bar-tasker": {
      "command": "/usr/bin/env",
      "args": ["python3", "/path/to/bar-tasker/scripts/bar_tasker_mcp_server.py"],
      "env": {
        "CHECKVIST_USERNAME": "you@example.com",
        "CHECKVIST_REMOTE_KEY": "your-remote-key",
        "CHECKVIST_LIST_ID": "123456"
      }
    }
  }
}
```

## Suggested First Calls

1. `checkvist_list_lists`
2. `checkvist_fetch_tasks` (omit `list_id` if default is set)
3. `checkvist_quick_add_task` with `location: "default"` and sample content
4. `checkvist_quick_add_task` with `location: "specific"` and `parent_task_id`
