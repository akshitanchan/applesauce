# applesauce

One native Swift binary that serves Apple apps on macOS over MCP (stdio).

check: xcrun swift-format lint --strict -r Sources Tests Package.swift && swift build
test: swift test --filter <Module>Tests

## layout
- `Sources/AppleSauceCore/`: registry, `Module` protocol, `ToolSpec`, `Arguments`, `ToolError`, `withTimeout`, permissions, doctor.
- `Sources/Mod<Name>/`: one target per module. A module talks to its app only through a small `Store` protocol.
- `Sources/applesauce/`: `main.swift` (CLI) and `TCCBootstrap.swift` (permission ownership). Register new modules in `features` in `main.swift`.
- `Support/Info.plist`: embedded in the binary by a linker flag. Keep its version in step with `AppleSauce.version`.

## rules
- Tests use fake stores only. Never read or change real calendars, reminders, contacts, mail or notes in tests.
- Every failure is a `ToolError` with `code`, `message` and `fix`.
- Check all input with `Arguments` before any permission request or app call.
- Every backend call runs inside `withTimeout` (30 s; permission waits 120 s).
- Read tools: `ToolSpec(write: false)`. Tools that change data: `write: true`. Delete or send: `destructive: true`.
- Run external programs with an argv array (`Process`), never through a shell.
- After a build that you want to run for real, sign it: `scripts/sign.sh <binary>`.
