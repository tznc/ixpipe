# AGENTS.md

ixpipe: an open-source, Alteryx-style DAG workflow orchestrator. Native
desktop and mobile app in Elixir, rendered by GPUI through
[baguette](https://github.com/ziinc/baguette) (Tauri host, embedded BEAM).

## Layout (umbrella)

- `apps/ixpipe_core`: the engine, pure Elixir with no UI dependency.
  - `IxpipeCore.Spec` parses YAML workflows: `decode/1` (drafts), `validate/1` (runnable DAG), `to_yaml/1`.
  - `IxpipeCore.Edit` applies canvas edits (add, move, connect, remove) to drafts.
  - `IxpipeCore.run/1` compiles a spec to a [Runic](https://hex.pm/packages/runic) workflow and runs it.
  - Tools (`IxpipeCore.Tools.*`) implement `IxpipeCore.Tool` over `Explorer.DataFrame`: `inputs/0`, `fields/0` (the settings schema the properties panel renders; `IxpipeCore.Config` parses and formats each type) and `run/2`. Register new ones in `IxpipeCore.Tools` and in the palette in `MainView`.
- `apps/ixpipe_app`: the Baguette UI. `IxpipeApp.MainView` is the main window: home (workflows in `IXPIPE_HOME`, default `~/ixpipe`) and the canvas (tool palette, scrolling canvas with curved wires, properties panel driven by each tool's `fields/0`, results grid of the selected tool's first 50 rows after a run). `IxpipeApp.Theme` holds the colour tokens; every colour class must resolve to one (tested).
  - Rust is only for platform NIFs.

## Rules

- **TDD for every feature and fix**: write the failing test first, see it fail, then implement. Styling-only changes are exempt.
- **All tests are Elixir (ExUnit).**
  - Engine: `apps/ixpipe_core/test`.
  - UI: headless `Baguette.Test` in `apps/ixpipe_app/test`.
  - End-to-end UI: `Baguette.Playwright` (gpui-playwright) in `apps/ixpipe_app/test/e2e`, tagged `:playwright` and excluded by default.
  - QA: screenshot QA (`:qa`) and a seeded chaos monkey (`:chaos`) in `apps/ixpipe_app/test/qa`; headless fuzzing in `main_view_fuzz_test.exs`. See `.claude/skills/app-qa/SKILL.md`; run it after UI changes, before reporting done.
- Never create atoms from workflow input. Ports, ids and config keys stay strings.
- Runic hashes steps by their fn plus bound variables, so build step fns inline (see `IxpipeCore.step/2`). A fn passed in as a variable gets the same hash for every node.
- When recommending actions, give options A/B/C plus a recommendation. Ask when something is ambiguous.
- No PRs unless asked. PR descriptions are 1-2 lines plus the session link.

## Design language

ixpipe follows ixtable's design language
([tznc/ixtable `docs/decisions/design-language.md`](https://github.com/tznc/ixtable/blob/main/docs/decisions/design-language.md)).
`IxpipeApp.Components` implements it; screens compose those components, and a
one-off style is a bug. `design_rules_test.exs` enforces what can be checked.

- **Colour** (`IxpipeApp.Theme`): gpui-kit's greys plus one accent, the
  ixtable teal `#0DB9B6` with white text (links `#0A7C7A`). Colour carries
  meaning (selection, status, danger), never decoration. Status is a tint
  plus text (`<.callout>`, `<.status_badge>`), never text colour alone.
  Selection is a teal tint and border. Disabled is 40% opacity.
- **Type scale**: `<.title>` (one per view), `<.section>`, `<.body>`,
  `<.label>`, `<.caption>`. Raw `text-*` sizes and `font-*` weights are
  allowed only in `components.ex` (tested).
- **Buttons** (`<.button variant=…>`): `:primary` completes the task, at most
  one per view (tested); `:secondary` for everything else; `:quiet` in
  dense lists and toolbars; `:danger` for delete, remove, drop and reset
  (tested); `:link` for breadcrumbs. Label with a verb and an object
  ("Save workflow", "Run workflow").
- **Layout**: left-aligned; only empty states and dialogs are centred.
  Spacing on the 4px scale: `gap-1` in a control group, `gap-3` between
  fields, `gap-6` between sections, `p-4` in a card.
- **Feedback never moves the layout**: run results and modes are a callout
  over the canvas; transient success ("Saved sales.yaml") is a `<.toast>`
  top right that clears after 6 s; errors read "what happened. what to do."
- **Empty states**: every list or canvas that can be empty has one: a
  title, one sentence, at most one action (tested on home and canvas).
- **Navigation**: drill-in uses `<.breadcrumb>` ("Workflows / sales.yaml"),
  not a Back button.
- **Words**: sentence case; tool names humanized ("Input CSV"); counts with
  correct plurals ("1 row", "4 rows"); dates relative within a week.

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

Postgres tests (`:postgres`, excluded by default) need a local server with a
role `ixpipe` and database `ixpipe_test`; override with `IXPIPE_PG_HOST`,
`IXPIPE_PG_PORT`, `IXPIPE_PG_DATABASE`, `IXPIPE_PG_USER`.

```sh
apt-get install -y postgresql && service postgresql start
runuser -u postgres -- psql -c "CREATE ROLE ixpipe LOGIN PASSWORD 'ixpipe-test'"
runuser -u postgres -- psql -c "CREATE DATABASE ixpipe_test OWNER ixpipe"
PGPASSWORD=ixpipe-test mix test --only postgres
```

`IXPIPE_WORKFLOW` opens a workflow straight onto the canvas.
