<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/icon.png">
    <img src="assets/icon-dark.png" alt="applesauce logo" width="128">
  </picture>
</p>

# applesauce

One MCP server for the Apple apps on your Mac.

![applesauce demo: an assistant plans a day with Calendar, Notes, Mail and Reminders (sample data)](assets/demo.gif)

applesauce is one small native program, written in Swift. It lets an AI assistant work with your Calendar, Reminders, Mail, Notes and Contacts. It can also run Shortcuts, search files with Spotlight, and use the clipboard. It talks to the assistant over MCP (the Model Context Protocol) on stdin and stdout.

- Needs macOS 14 or newer. Works on Apple silicon and Intel.
- No account, no cloud. Everything runs on your Mac.
- Mail search is fast when it can read the Mail index (see Full Disk Access below).
- Every error says what went wrong and how to fix it.

## Tools

42 tools in 8 modules, plus `doctor`.

| Module | Tools |
|---|---|
| calendar | `list_calendars`, `list_events`, `search_events`, `get_event`, `create_event`, `update_event`, `delete_event` |
| reminders | `list_reminder_lists`, `list_reminders`, `search_reminders`, `get_reminder`, `create_reminder`, `update_reminder`, `complete_reminder`, `delete_reminder` |
| mail | `list_accounts`, `list_mailboxes`, `search_mail`, `get_message`, `create_draft`, `send_mail`, `reply`, `move_message`, `flag_message`, `mark_read`, `delete_message` |
| notes | `list_folders`, `search_notes`, `get_note`, `create_note`, `append_to_note`, `move_note`, `delete_note` |
| contacts | `search_contacts`, `get_contact` |
| shortcuts | `list_shortcuts`, `run_shortcut` |
| spotlight | `search_files` |
| system | `get_clipboard`, `set_clipboard`, `notify`, `open` |
| always on | `doctor` |

## Install

You need macOS 14 or newer. For the npm route you also need Node 18 or newer.

### Claude Code

```sh
claude mcp add applesauce -- npx -y applesauce
```

### Claude desktop with npx

Open `~/Library/Application Support/Claude/claude_desktop_config.json` and add this:

```json
{
  "mcpServers": {
    "applesauce": {
      "command": "npx",
      "args": ["-y", "applesauce"]
    }
  }
}
```

Restart Claude desktop. To add a flag, put it in `args`, for example `["-y", "applesauce", "--read-only"]`.

### Claude desktop with the .mcpb bundle

1. Download `applesauce-<version>.mcpb` from the GitHub releases page.
2. Double-click the file. Claude desktop opens an install dialog.
3. Click Install. The dialog has three settings: read-only mode, only these modules, turn off these modules.

### Any other MCP client

Run `npx -y applesauce`. It speaks MCP on stdin and stdout.

## Flags and environment variables

```
applesauce [serve] [options]   run the MCP server (default)
applesauce doctor [options]    show the state of each macOS permission and how to fix it
applesauce --version
applesauce --help
```

| Flag | Environment variable | Meaning |
|---|---|---|
| `--modules a,b` | `APPLESAUCE_MODULES` | Turn on only these modules. |
| `--disable a,b` | `APPLESAUCE_DISABLE` | Turn off these modules. |
| `--read-only` | `APPLESAUCE_READ_ONLY=1` | Hide every tool that changes data. |

Module names: `calendar`, `reminders`, `mail`, `notes`, `contacts`, `shortcuts`, `spotlight`, `system`. A flag wins over its environment variable. An empty `APPLESAUCE_MODULES` means all modules.

## Permissions

macOS keeps your data private. The first time a tool needs an app, macOS shows a prompt. Click Allow. The prompt names applesauce, not your terminal or Claude.

| Permission | Used by | Notes |
|---|---|---|
| Calendars | calendar | Prompt on the first calendar tool. Full access, so events can be read and changed. |
| Reminders | reminders | Prompt on the first reminders tool. |
| Contacts | contacts | Prompt on the first contacts tool. |
| Automation for Mail | mail | Prompt on the first mail tool. Mail must be running. |
| Automation for Notes | notes | Prompt on the first notes tool. Notes must be running. |
| Full Disk Access | mail search | Optional. Gives fast search over all mail. |

Spotlight, Shortcuts, the clipboard, `notify` and `open` need no permission of their own.

### Full Disk Access for fast Mail search

Without it, `search_mail` still works. It is slower, needs a mailbox, and looks at a date range only. With it, applesauce reads the Mail index directly, read-only.

1. Ask your assistant to run the `doctor` tool, or run `npx -y applesauce doctor` in a terminal. Copy the `binary:` path.
2. Open System Settings, Privacy & Security, Full Disk Access.
3. Click `+`. Press Cmd+Shift+G and paste the path. Select the binary and click Open.
4. Restart your AI app.

### Permissions reset after an update

applesauce has no paid Apple signing, only an ad-hoc signature. macOS ties a permission to the exact binary. After each update, macOS may ask again, and Full Disk Access must be added again. With `npx`, a new version is a new file, so the same applies.

After an update, ask your assistant to run the `doctor` tool, or run `npx -y applesauce doctor`. It shows each permission, its state, and the exact step that fixes it. If a permission shows as denied, open System Settings, Privacy & Security, find applesauce in the list, and turn it off and on again.

## Safety

- `--read-only` (or the read-only switch in the .mcpb dialog) hides every tool that changes data.
- `send_mail` and `reply` send nothing unless the call has `confirm: true`. Without it they save a draft.
- Tools that delete, send or move mail are marked `destructiveHint: true`. Most MCP clients ask you before they run them.
- Tools that only read are marked `readOnlyHint: true`.
- `run_shortcut` runs a shortcut, and a shortcut can do anything on your Mac. Turn off the `shortcuts` module if you do not want that.
- Every call has a time limit (30 seconds, and 120 seconds for a permission prompt).
- Mail attachment content is never returned. Contact notes are never returned.

### What can be undone

| Action | Undo | Gate |
|---|---|---|
| Delete a note | Notes keeps it in Recently Deleted for 30 days. | none |
| Delete up to 10 emails | Mail moves them to the Trash. | none |
| Delete more than 10 emails, or move them to Trash or Junk | Mail moves them to the Trash or Junk. | `confirm: true` |
| Delete emails that are already in the Trash | None. The delete is final. | `confirm: true` |
| Delete an event or a reminder | The result has a full copy, so the assistant can create it again (with a new id). | none |
| Delete all later occurrences of a recurring event | None. | `confirm: true` |

Without `confirm: true`, a gated call changes nothing and says why. Your assistant can still pass `confirm: true` by itself, so `--read-only` is the only hard block.

## Limits

- macOS 14 or newer.
- No paid Apple signing and no notarization. Permissions reset after an update (see above).
- Locked notes are not read.
- Mail and Notes must be running. Mail search with Full Disk Access is the one exception.
- The Intel slice is built but not tested on Intel hardware.

## Build from source

You need Xcode with Swift 6.1 or newer.

```sh
swift build
swift test
scripts/sign.sh .build/debug/applesauce   # needed for macOS to show permission prompts
```

Release build and packages:

```sh
scripts/build-universal.sh   # dist/applesauce, arm64 + x86_64, ad-hoc signed
scripts/pack-npm.sh          # dist/applesauce-<version>.tgz
scripts/pack-mcpb.sh         # dist/applesauce-<version>.mcpb
scripts/version.sh --check   # all version numbers agree
```

The version lives in `Sources/AppleSauceCore/Version.swift`. `Support/Info.plist`, `npm/package.json` and `mcpb/manifest.json` must match it.

## Credits

- The self-disclaim pattern, which makes the binary own its permission prompts, comes from apple-reminders-mcp ([source](https://github.com/high5-ventures/apple-reminders-for-claude)) by high5 ventures (MIT).
- Built on the [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk).

## License

MIT. See `LICENSE`.
