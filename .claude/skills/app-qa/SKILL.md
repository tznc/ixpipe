---
name: app-qa
description: >-
  Verify ixpipe UI and interaction changes: fuzz screens headlessly with
  Baguette.Test and StreamData, screenshot-verify the real app driven through
  gpui-playwright from ExUnit (apps/ixpipe_app/test/qa), and chaos-test it
  with a seeded monkey. Use on /app-qa, when asked to QA, screenshot or
  chaos-test a behaviour, and proactively after changing apps/ixpipe_app/**
  or core code a screen reads (IxpipeCore.Spec, IxpipeCore.Edit, tools),
  before reporting done.
---

# App QA (screenshot-verified behaviour checks)

ixpipe's UI is Elixir (`Baguette.View`s in `apps/ixpipe_app`), rendered by
GPUI in baguette's Tauri host. Every test is ExUnit. QA has three layers:
pick the lightest one that proves the change, and always look at the pixels
for anything visual.

| Layer | Tool | Runs | Use for |
|---|---|---|---|
| Screen tests and fuzzing | `Baguette.Test` + StreamData | headless, in `mix test` | one screen's behaviour; invariants under random input |
| Screenshot QA | `IxpipeApp.QA` over `Baguette.Playwright`, `apps/ixpipe_app/test/qa` (`:qa`) | the real release under Xvfb | what a change looks like |
| Chaos QA | seeded monkey, `test/qa/chaos_test.exs` (`:chaos`) | the real release under Xvfb | crashes, hangs, unreachable controls, bad errors |

## When to use

- The user invokes `/app-qa`, optionally naming a flow ("app-qa the canvas").
- Proactively, after an edit to `apps/ixpipe_app/**` or to core code a
  screen reads, before telling the user the change is done.

## Delegate the legwork

Hand discovery to cheaper subagents (`Agent` with `model: "haiku"`, or
`"sonnet"` when it needs reasoning), in parallel where independent: which test
already sets up the state you need, what label a control has, which
`IxpipeCore` function backs an action. Ask for the specific fact. Keep for
yourself: deciding what to verify, writing the expectations, reading the PNGs
(step 5) and the report.

## Making elements findable

Both layers find controls the way a screen reader does: by `aria-label` (or,
without one, the element's text). Give every `phx-click` and `phx-drag`
element a unique `aria-label` (`"Add sort"`, `"Connect to sort_1 in"`,
`"Remove orders"`), rather than querying by position. Playwright's
`getByRole('button', {name})` reads the same label: baguette registers every
element with gpui-kit when the host is built with its `playwright` feature.

## Layer 1: screen tests and fuzzing

- Behaviour tests live in `apps/ixpipe_app/test/ixpipe_app/*_test.exs`: start
  the view with `start_supervised!({IxpipeApp.MainView, window: w, theme:
  IxpipeApp.Theme, args: [dir: tmp]})`, act with `Baguette.Test.click/2` and
  `drag/4`, assert on `Baguette.Test.text/1` and on saved YAML. These send the
  same events the native host does, so never call `handle_event/3` directly.
- `main_view_fuzz_test.exs` drives random sequences of whatever
  `IxpipeApp.UI.actions/1` offers (every `phx-click` and `phx-drag` in the
  frame) and checks invariants after every step: the view is alive, every
  colour class resolves to a theme token, there is always something to do,
  node ids are unique, edges point at nodes, and the workflow round-trips
  through YAML. Add an invariant when you add state. Hunt with
  `FUZZ_RUNS=2000 mix test apps/ixpipe_app/test/ixpipe_app/main_view_fuzz_test.exs`;
  turn a shrunk failure into a plain test in `main_view_test.exs`.
- Engine behaviour belongs in `apps/ixpipe_core/test`, not here.

## Layer 2: screenshot QA

1. **Build the release with the Playwright server** (after any change to
   app, core or the baguette ref):
   `BAGUETTE_HOST_FEATURES=playwright MIX_ENV=prod mix release ixpipe --overwrite`
   with `BAGUETTE_LIBERLANG` set and that OTP's `bin` first on `PATH`
   (see AGENTS.md).
2. **Pick or write a spec** in `apps/ixpipe_app/test/qa/<area>_qa_test.exs`,
   `@moduletag :qa`. One file per area; extend a `describe` rather than
   duplicating setup. `IxpipeApp.QA.launch!(open: "sales.yaml")` seeds a
   workflows home (a six-node sales workflow over `test/qa/fixtures` CSVs, and
   an empty `scratch.yaml`) and opens the app on it; stop it with
   `QA.stop/1` in `on_exit`. Drive the app only through user actions:
   `Baguette.Playwright.click/2`, `drag/4`, and wait with `await_text/3`.
   Build scenario state through the UI; seed only incidental state.
3. **Capture with expectations.** `QA.capture(page, name, expectations)`
   writes `<name>.png` and `<name>.json` to `apps/ixpipe_app/test/qa/.shots`
   (or `QA_OUT`). Name captures `<area>-<NN>-<what-it-shows>`. Expectations
   are at most three plain-English claims about the picture; keep real
   assertions in the spec too, since they prove the state before the capture.
   `await_text/3` is strict: text shown twice (`"4 rows"`) matches twice and
   fails, so wait on something unique.
4. **Run it** under Xvfb from the umbrella root:
   `xvfb-run -a -s "-screen 0 1600x1000x24" mix test apps/ixpipe_app/test --only qa`.
   `QA_BIN` picks another binary and `QA_PORT` another port (default 9340),
   so two runs can share a machine.
5. **Verify every capture against its expectations.** Read each
   `<name>.json`, then open `<name>.png` with the Read tool and confirm or
   refute each claim. A spec whose assertions passed can still render a
   broken layout, clipped text, unresolved colours (black on black), edges
   behind cards or a stuck status; that is a bug to fix.
6. **Show the result.** Publish the PNGs as an Artifact (a simple gallery:
   each image with its name and expectations, and your verdict) and give the
   user the link, calling out any expectation that did not hold.

## Layer 3: chaos QA

`xvfb-run -a mix test apps/ixpipe_app/test --only chaos` runs a seeded monkey
on the canvas: 60% clicks on a random button from the window's ARIA snapshot
(`Baguette.Playwright.buttons/1`), 30% drags of a random node by up to 150px,
10% mouse-wheel scrolls of the canvas (`Baguette.Playwright.scroll/4`).
Clicks on controls scrolled out of view (Playwright: "not stable",
"outside of the viewport", "scrolling into view") are skipped, as a user
would scroll first.
After each step it checks the app process is alive, Playwright still
answers, and the app log has no `panicked`. A failure prints the seed, the
action trail and a screenshot (`chaos-<seed>-failure.png`). Replay with
`QA_SEED=<seed>`; lengthen with `QA_STEPS=500`. A click that times out
means a control became unreachable (a node dragged off the canvas, a button
covered by another): that is a bug. Pin each bug with a layer 1 or core test
before fixing it. For a hunting session, run several seeds.

## Linux and Xvfb notes

- The Tauri host needs a display (GTK): always run under `xvfb-run -a`.
- Without a theme, `bg-*`/`text-*` tokens resolve to nothing and the window
  screenshots black. The theme test in `main_view_test.exs` guards this.
- `Baguette.Playwright.stop_app/1` waits for the process to exit, so the next
  test can reuse the port.

## Finish

After the behaviour is verified and shown: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix test`, and `--only playwright`
under Xvfb. Keep the QA specs: `apps/ixpipe_app/test/qa` is a growing
visual-regression library, not scratch.
