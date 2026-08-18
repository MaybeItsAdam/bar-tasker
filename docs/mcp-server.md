# MCP Server Guide

Priority ships an MCP stdio server so an AI assistant can work directly with your Checkvist data.

- Server command: `priority mcp` — the CLI, which the app ships at
  `Contents/Helpers/priority`. `Priority --mcp-server` also works and hands over
  to it; see [One server, two ways to name it](#one-server-two-ways-to-name-it)
- Transport: stdio, newline-delimited JSON — one JSON-RPC object per line, as the
  MCP stdio transport specifies. LSP-style `Content-Length` framing is also
  accepted, and replies mirror whichever framing the client used.
- Dependencies: none beyond Priority itself — the server ships inside the app

## What It Can Do

The server exposes 19 MCP tools, in two groups.

**Checkvist tools** — these reach the Checkvist API directly, so they work
whether or not the app is running:

| Tool | What it does |
|---|---|
| `task_lists` | List non-archived checklists |
| `list_create` | Create a checklist |
| `task_fetch` | Fetch a list's tasks (open only by default) |
| `task_search` | Filter by content substring, tag, and/or due date |
| `task_add` | Quick-add at the root or under a specific parent |
| `task_update` | Change content and/or due |
| `task_note_add` | Append a note (a Checkvist comment) |
| `task_move` | Reorder among siblings (1-based position) |
| `task_reparent` | Move under a different parent, or to the root |
| `task_complete` | Close a task |
| `task_reopen` | Reopen a task |
| `task_invalidate` | Mark "won't do" |
| `task_delete` | Delete a task |

**Local tools** — these reach the state Priority keeps on this machine, which
Checkvist has no representation for:

| Tool | What it does | |
|---|---|---|
| `daily_log_fetch` | What happened on recent days: completions, focus time, unfinished/deferred tasks, daily ticks | read |
| `dailies_list` | Configured dailies with today's schedule and tick state | read |
| `task_metadata` | Priority ranks (scoped and absolute), recurrence rules, start dates, Eisenhower urgency/importance, kanban columns | read |
| `daily_add` | Create a daily | write |
| `daily_update` | Rename, reschedule, archive/unarchive a daily | write |
| `daily_tick` | Tick or un-tick a daily for today | write |

Notes:

- The Checkvist tools talk directly to the Checkvist API.
- It does not automate the local macOS app UI.
- `task_add` supports both root insertion and specific parent insertion.
- The local tools need no IPC. They read the app's preferences plist by bundle
  id and the day-log files at the same Application Support path, under the same
  `flock` protocol the app uses.
- `task_metadata` is read-only, and stays that way. Priorities, recurrence and
  start dates live in `UserDefaults`, which the running app holds in memory and
  rewrites on its own schedule — there is no equivalent of the file lock below
  that would let an external write survive. Setting those has to go through the
  app.

### How the daily writes stay safe

Two processes edit `dailies.json` and `daylog.jsonl`: the app and this server.
Three things make that safe, and all three are load-bearing:

1. **A file lock.** `FileLock` (`Sources/PriorityCore/FileLock.swift`) takes `flock(2)` on a
   sibling `.lock` file — a sibling, because saves are atomic (temp + rename) and
   replace the data file's inode, so a lock held on it guards nothing. The CLI
   takes the same lock on the same path, so the two genuinely exclude each
   other.
2. **Read/modify/write, never save-a-snapshot.** `DailyDefinitionsStore.mutate`
   re-reads inside the lock and applies the change to what is on disk *now*. The
   app used to write its launch-time copy back wholesale, which silently erased
   anything added since. A mutation must be expressed as *what changed*.
3. **A directory watcher.** `DailyLogService` watches the store directory (not
   the files — the rename would orphan a file watch) and reloads, so a daily
   added here shows up in the popover without a relaunch.

The serialised format is therefore a cross-process interface. Two constraints
are pinned by `DailyDefinitionsStoreFormatTests`:

- Dates are `yyyy-MM-ddTHH:mm:ssZ` with **no fractional seconds**. The Swift
  decoder is `.iso8601`, which rejects them, and `load()` turns a decode failure
  into an *empty* collection — so one bad timestamp makes every daily vanish and
  the next save persists that emptiness.
- `activeWeekdays` is written sorted, so saves don't churn the file.

A daily is scheduled *either* on weekdays *or* on a cycle. `intervalDays` (with
`intervalAnchor`, a day the cycle lands on) is present only for the second kind
and takes over from `activeWeekdays` entirely — the weekday set stays on the
record so that ending the cycle restores it. Both fields are absent on every
daily written before cycles existed, which decodes as the weekday case. In the
tools this is `interval_days`: passing it alongside `active_weekdays` is refused
rather than resolved in favour of whichever the implementation checks first, and
passing `active_weekdays` to `daily_update` clears an existing cycle.

### One server, two ways to name it

There is one implementation: the `priority` CLI (`cli/src/mcp.rs`). The app
**ships** it, at `Contents/Helpers/priority`, installed during the build by
`scripts/bundle_cli.sh` and signed with the app.

| Command | What happens |
|---|---|
| `priority mcp` | The server, directly. What newly written configurations use. |
| `Priority --mcp-server` | `MCPServerShim` `execv`s the bundled helper. What configurations written before this change say. |

Because the app bundles the CLI, `Priority --mcp-server` works on a machine
where the CLI was never installed separately — which is what made retiring the
old server safe.

There used to be a second implementation: 1,760 lines of Swift in
`Priority/Plugins/MCP/MCPServer.swift`, running in-process. A third, a bundled
`python3` fallback script, went earlier. Both existed for the same reason — a
client might be pointed at any of them — and both cost the same thing: every
tool change was a two- or three-way edit, and every divergence a two- or
three-way diff. They were held equal from the outside by
`scripts/mcp_parity_check.py`, which drove each over stdio and compared tool
lists, answers, files written, and HTTP requests, because neither could import
the other.

What kept the Swift one alive was never a capability the CLI lacked; the parity
check proved that every one of the nineteen tools agreed. It was that MCP client
configurations already written to users' disks name
`/Applications/Priority.app/Contents/MacOS/Priority --mcp-server`. Bundling the
CLI and turning that path into a shim removed the reason, so:

- ~1,760 lines of Swift are gone, as is ~610 lines of parity harness and a CI
  job;
- there is one implementation to be correct rather than two to keep equal;
- and existing configurations keep working untouched, because the CLI already
  accepted the bare `--mcp-server` flag (`cli/src/main.rs`) and already reads
  credentials from the environment ahead of its own config file
  (`cli/src/config.rs`) — which is exactly where a client configuration puts
  them.

`cargo test` covers the server. `scripts/mcp_smoke_check.py` covers the seam:

```bash
python3 scripts/mcp_smoke_check.py   # needs a Debug app build
```

It drives both spellings above and checks they answer `initialize` and expose
the same nineteen tools — in particular that an old-style invocation, with
credentials in `env`, still reaches a working server. It reads no real data and
needs no Checkvist credentials.

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

Priority detects Claude Code, Claude Desktop, Cursor, Windsurf, VS Code, and
Zed. What the button does depends on the client, because the wrong route is worse
than no route:

| Client | Action | Why |
|---|---|---|
| Claude Desktop, Cursor, Windsurf, VS Code | Writes the config file | Plain JSON files that hold nothing but MCP config |
| Claude Code | Copies a `claude mcp add-json` command to run | Claude Code rewrites `~/.claude.json` constantly; editing it underneath would race |
| Zed | Copies a snippet to paste | `settings.json` carries comments that a JSON rewrite would delete |

Direct writes **merge**: your other MCP servers and every unrelated key survive.
If the existing file isn't valid JSON, Priority refuses rather than replacing
it. Keys come back sorted, so expect the file to be reformatted once.

Config writes go straight to the client's file — release builds are not
sandboxed (see `Priority.release.entitlements` for why), so no folder-access
prompt is involved and credential changes re-install silently.

If nothing is detected, use **Copy Client Config** and paste it in by hand — the
rest of this guide covers that.

## Configuration

Set these environment variables for the MCP process (in your MCP client config):

- `CHECKVIST_USERNAME` (required)
- `CHECKVIST_REMOTE_KEY` (required)
- `CHECKVIST_LIST_ID` (optional default list)
- `CHECKVIST_BASE_URL` (optional, defaults to `https://checkvist.com`)

The server falls back to the CLI's own config file
(`~/.config/priority/config.json`, written by `priority auth login`) when these
are unset, so a client config can omit the `env` block entirely. The environment
still wins where it is set — which is what makes a configuration written before
the migration, with credentials in `env`, keep behaving exactly as it did. See
`docs/cli.md`.

If `CHECKVIST_LIST_ID` is not set, pass `list_id` in tool calls that need a list.

Command resolution priority, used both by the settings pane when it generates a
config and by `MCPServerShim` when `--mcp-server` looks for something to run:

1. `PRIORITY_MCP_EXECUTABLE_PATH` (explicit override — point a development build
   at a freshly built CLI without reinstalling the app)
2. The bundled helper: `/Applications/Priority.app/Contents/Helpers/priority`,
   then the same path relative to the running bundle
3. A separately installed CLI: `~/.local/bin`, `~/bin`, `/usr/local/bin`,
   `/opt/homebrew/bin`

If none resolves, a generated config points at
`/Applications/Priority.app/Contents/Helpers/priority` so it is obvious what to
fix, and `--mcp-server` exits with the list of paths it tried on stderr, where
the client will log it.

Extra control env vars:

- `PRIORITY_MCP_GUIDE_PATH` to override guide detection

## Run Manually

```bash
CHECKVIST_USERNAME="you@example.com" \
CHECKVIST_REMOTE_KEY="your-remote-key" \
CHECKVIST_LIST_ID="123456" \
'/Applications/Priority.app/Contents/Helpers/priority' mcp
```

It will wait for an MCP client to connect over stdio.

## Client Config Example

Most MCP clients accept a JSON config similar to this:

```json
{
  "mcpServers": {
    "priority": {
      "command": "/Applications/Priority.app/Contents/Helpers/priority",
      "args": ["mcp"],
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

A configuration written before the CLI was bundled names the app binary instead:

```json
{
  "mcpServers": {
    "priority": {
      "command": "/Applications/Priority.app/Contents/MacOS/Priority",
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

That still works — the app hands the process to the bundled helper — so there is
nothing you have to change.

A separately installed CLI works too, if you have run `scripts/install_cli.sh`:

```json
{ "mcpServers": { "priority": { "command": "/usr/local/bin/priority", "args": ["mcp"] } } }
```

## Suggested First Calls

1. `task_lists`
2. `task_fetch` (omit `list_id` if default is set)
3. `task_add` with `location: "default"` and sample content
4. `task_add` with `location: "specific"` and `parent_task_id`
