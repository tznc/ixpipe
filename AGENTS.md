# AGENTS.md

ixpipe: an open-source, Alteryx-style DAG workflow orchestrator. Native
desktop and mobile app in Elixir, rendered by GPUI through
[baguette](https://github.com/ziinc/baguette) (Tauri host, embedded BEAM).

## Layout (umbrella)

- `apps/ixpipe_core`: the engine, pure Elixir with no UI dependency.
  - `IxpipeCore.Spec` parses YAML workflows: `decode/1` (drafts), `validate/1` (runnable DAG), `to_yaml/1`.
  - `IxpipeCore.Edit` applies canvas edits (add, move, connect, remove) to drafts.
  - `IxpipeCore.run/1` compiles a spec to a [Runic](https://hex.pm/packages/runic) workflow and runs it.
  - Tools (`IxpipeCore.Tools.*`) implement `IxpipeCore.Tool` over `Explorer.DataFrame`; register new ones in `IxpipeCore.Tools`.
- `apps/ixpipe_app`: the Baguette UI. `IxpipeApp.MainView` is the main window: home (workflows in `IXPIPE_HOME`, default `~/ixpipe`) and the canvas. `IxpipeApp.Theme` holds the colour tokens; every colour class must resolve to one (tested).
  - Rust is only for platform NIFs.

## Rules

- **TDD for every feature and fix**: write the failing test first, see it fail, then implement. Styling-only changes are exempt.
- **All tests are Elixir (ExUnit).**
  - Engine: `apps/ixpipe_core/test`.
  - UI: headless `Baguette.Test` in `apps/ixpipe_app/test`.
  - End-to-end UI: `Baguette.Playwright` (gpui-playwright) in `apps/ixpipe_app/test/e2e`, tagged `:playwright` and excluded by default.
- Never create atoms from workflow input. Ports, ids and config keys stay strings.
- Runic hashes steps by their fn plus bound variables, so build step fns inline (see `IxpipeCore.step/2`). A fn passed in as a variable gets the same hash for every node.
- When recommending actions, give options A/B/C plus a recommendation. Ask when something is ambiguous.
- No PRs unless asked. PR descriptions are 1-2 lines plus the session link.

## Toolchain

- OTP 29.1.2 and Elixir 1.20.4 (match baguette's CI).
- Rust stable.
- Linux GPUI deps: see baguette's CI.
- Android: SDK 34 and NDK 27.2.12479018.

```sh
mix test                      # all apps
mix test apps/ixpipe_core/test
mix format --check-formatted

# End-to-end: a release with the host's playwright feature, under a display.
# Needs BAGUETTE_LIBERLANG (scripts/build-liberlang.sh in baguette) and that
# OTP install's bin on PATH.
BAGUETTE_HOST_FEATURES=playwright MIX_ENV=prod mix release ixpipe --overwrite
xvfb-run -a mix test --only playwright
```

`IXPIPE_WORKFLOW` opens a workflow straight onto the canvas.
