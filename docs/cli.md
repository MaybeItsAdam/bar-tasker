# CLI Guide

`priority` is a Rust command-line tool for the same data the app works with:
your Checkvist lists, your dailies, and your day log.

It is a peer of the app rather than a remote control for it. It talks to the
Checkvist API directly and reads Priority's local files off disk, so every
command works whether or not the app is running — and the writes take the same
file lock the app does, so both can be open at once.

```bash
./scripts/install_cli.sh     # builds release and links `priority` onto your PATH
priority --help
```

Or without installing:

```bash
cargo build --release --manifest-path cli/Cargo.toml
cli/target/release/priority dailies
```

## Signing in

```bash
priority auth login
```

It prompts for your Checkvist email and your remote key (from
[checkvist.com/auth/profile](https://checkvist.com/auth/profile), read without
echo), checks them against the API, and only then writes them to
`~/.config/priority/config.json` with mode 0600. A mistyped key fails at this
point rather than as a puzzling 401 on some later command.

```
priority auth status        where the config lives and what is in effect
priority auth set-list ID   the default list, used when --list-id is omitted
priority auth logout        forget the key; --all deletes the file
priority auth path          just the path, for scripts
```

`auth status` never prints the remote key — only its length, which is enough to
spot a truncated paste.

### These credentials are the CLI's own

Signing in here does not sign you in to the Priority app, and signing in to
the app does not sign in the CLI. That is deliberate. The app keeps its remote
key in the login keychain, where it is reachable only by something carrying the
app's code signature; a CLI that depended on it would work or not depending on
how the app happened to be built and signed that day. Its own file is
predictable, portable, and works on a machine with no app installed.

The trade is that the key sits in a plain file rather than the keychain, as CLI
credential files conventionally do. It is created mode 0600 from the moment it
exists — not chmod-ed afterwards, since the gap between the two is a window in
which it is world-readable.

### Environment variables still win

- `CHECKVIST_USERNAME`, `CHECKVIST_REMOTE_KEY`, `CHECKVIST_LIST_ID`
- `CHECKVIST_BASE_URL` — defaults to `https://checkvist.com`
- `PRIORITY_MCP_STORE_DIR`, `PRIORITY_MCP_PREFS_PATH` — where the local
  files are read from
- `PRIORITY_CONFIG_PATH`, or `XDG_CONFIG_HOME` — where the config file itself
  lives

Any of these set in the environment beats the file, so an MCP client config that
passes credentials keeps working untouched, and `CHECKVIST_LIST_ID=999 priority
tasks` is a one-off override. `auth status` says which source each value came
from, and the auth commands warn you when a variable is shadowing what they just
wrote.

The dailies, day-log and metadata commands read local files and need no
credentials at all, so they work before you have signed in to anything.

### Editing the file by hand

```json
{
  "username": "you@example.com",
  "remote_key": "...",
  "list_id": "945183",
  "base_url": "https://checkvist.com",
  "store_directory": "~/Library/Application Support/Priority"
}
```

Every key is optional. `~` is expanded in the path keys. A missing or malformed
file is treated as an empty config rather than an error — `priority dailies`
has no business failing over a credential file it never consults.

`store_directory` defaults to the app's own location, and that default is the
one place the CLI and the app are deliberately joined: reading the dailies and
day log the app writes is the whole reason those commands exist. Point it
elsewhere for a CLI-only setup.

## Commands

```
  lists       List your non-archived checklists
  new-list    Create a new checklist
  tasks       Show a list's tasks as a tree
  search      Search a list by content, tag and/or due date
  add         Add a task
  update      Change a task's content and/or due date
  note        Append a note to a task
  move        Reorder a task among its siblings. Position is 1-based
  reparent    Move a task under a different parent, or to the list root
  done        Complete a task
  reopen      Reopen a completed task
  invalidate  Mark a task "won't do"
  rm          Delete a task
  log         What actually happened on recent days
  dailies     Show your dailies with today's schedule and tick state
  daily       Create, change or tick a daily
  metadata    Priority's own per-task state: priority ranks, recurrence, start dates
  auth        Store, check or clear this CLI's Checkvist credentials
  mcp         Run as an MCP stdio server
  tools       List the tools this binary exposes
  call        Call a tool by name with raw JSON arguments
```

Two global options: `--list-id` and `--json`. `--json` prints the raw payload
instead of the rendering, which is the same JSON the MCP tool of that name
returns — useful for `jq`, and for checking what an assistant would have seen.

### Examples

```bash
priority lists
priority tasks                             # the default list, open tasks, as a tree
priority tasks --all                       # include closed and "won't do"
priority search -q report --due-before 2026-09-01
priority search -t work --limit 10

priority add Draft the release notes --due friday
priority add Check the numbers --parent 12345
priority note 12345 Waiting on the design review
priority done 12345

priority log --days 7
priority dailies
priority daily add Read for twenty minutes --weekdays mon,wed,fri
priority daily tick 5F385C47-E2A6-488E-B3E1-84B0511FFAD4
priority daily update <id> --archive

priority --json dailies | jq '.dailies[] | select(.done | not)'
```

`--weekdays` takes what you would actually type: `mon,wed,fri`, `weekdays`,
`weekend`, `every day`, or `Calendar` numbers where 1 is Sunday. The numbers are
what everything downstream sees; the spellings exist only at this boundary.

### The escape hatch

Every command is one of the nineteen MCP tools under a friendlier name. If you
want the tool directly:

```bash
priority tools
priority call daily_add '{"title": "Stretch", "active_weekdays": [2,4,6]}'
priority call task_search '{"query": "invoice", "include_closed": true}'
```

This is not a fallback for missing features — it is the same dispatch table the
subcommands go through. It exists so that a tool argument the CLI has no flag
for is still reachable, and so `priority call` can be used to reproduce exactly
what an assistant did.

## As an MCP server

The same binary is also the third MCP server implementation:

```bash
priority mcp
priority --mcp-server     # accepted too, so a config written for the app works unchanged
```

Point a client at it the same way as at the app, swapping the command. If you
have run `auth login`, no `env` block is needed at all — this is the one thing
the Rust server can do that the other two cannot, since they have no config file
to fall back on:

```json
{
  "mcpServers": {
    "priority": {
      "command": "/Users/you/.local/bin/priority",
      "args": ["--mcp-server"]
    }
  }
}
```

Passing credentials in `env` still works and still takes precedence, which is
why that asymmetry costs nothing: every existing config keeps behaving
identically, and `scripts/mcp_parity_check.py` drives all three with the
credentials in the environment (and with `PRIORITY_CONFIG_PATH` pointed at a
file that does not exist) so this file can never make the Rust one answer
differently.

See `docs/mcp-server.md` for the tool list and for how the three implementations
are held to the same behaviour.

## Editing dailies while the app is open

Both processes edit `dailies.json` and `daylog.jsonl`, and both go through the
same `flock(2)` on the same sibling `.lock` file, so a write from here cannot
interleave with one from the app. The CLI also re-reads the file inside the lock
rather than saving a snapshot it loaded earlier, which is what stops a
concurrent write being silently erased.

The app watches its store directory, so a daily added here appears in the
popover without a relaunch.

What is *not* writable from here is `metadata` — priority ranks, recurrence
rules and start dates. Those live in `UserDefaults`, which the running app holds
in memory and rewrites on its own schedule, so there is no file lock that would
let an external write survive. Setting them has to go through the app.

## Layout

```
cli/
  Cargo.toml
  src/
    main.rs       entry point; --mcp-server is intercepted before argument parsing
    cli.rs        subcommands, the auth commands, and the renderings
    tools.rs      the nineteen tools, implemented once
    checkvist.rs  the API client
    config.rs     ~/.config/priority/config.json, and the environment-first rule
    local.rs      dailies, day log, and preferences, off disk
    lock.rs       flock(2), shared with the app and the Python server
    mcp.rs        the JSON-RPC stdio server and the tool schemas
    tests.rs      unit tests
```

`cli.rs` and `mcp.rs` are both front ends onto `tools.rs`. Neither implements a
tool, so the CLI and the MCP server cannot drift apart — a command that cannot
be expressed as a tool call does not belong in `cli.rs`.

The crate is deliberately outside both `Package.swift` and the Xcode project: it
shares no source with them, and nothing in `Priority/` should ever `import` it.

## Developing

```bash
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
cargo fmt --manifest-path cli/Cargo.toml --check
python3 scripts/mcp_parity_check.py      # needs a Debug app build and a release CLI build
```

The parity check is the one that matters after a behaviour change: it drives all
three MCP servers and diffs their answers, the files they leave on disk, and the
HTTP requests they make. CI runs all four.
