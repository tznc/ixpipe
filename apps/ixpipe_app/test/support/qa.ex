defmodule IxpipeApp.QA do
  @moduledoc """
  Drives the real ixpipe release for screenshot QA and chaos runs (see
  `.claude/skills/app-qa`). Needs a release built with the host's
  `playwright` feature and a display (`xvfb-run`).

  Environment: `QA_BIN` (default: the umbrella's prod release), `QA_PORT`
  (default 9340) and `QA_OUT` (default `apps/ixpipe_app/test/qa/.shots`).
  """

  alias Baguette.Playwright

  @release Path.expand("../../../../_build/prod/rel/ixpipe/bin/ixpipe_app", __DIR__)
  @fixtures Path.expand("../qa/fixtures", __DIR__)

  @doc """
  Seeds a workflows home, starts the app on it and connects. `open:` names a
  seeded workflow to open on the canvas (default: the home screen); `env:`
  adds environment variables, such as baguette's `BAGUETTE_PICK_FILE`
  answer for native file dialogs; `workflows:` adds `{file, yaml}` pairs to
  the home.
  Returns `%{app, page, home}`; stop it with `stop/1`.
  """
  def launch!(opts \\ []) do
    home = Path.join(System.tmp_dir!(), "ixpipe-qa-#{System.unique_integer([:positive])}")
    seed!(home)

    for {file, yaml} <- Keyword.get(opts, :workflows, []),
        do: File.write!(Path.join(home, file), yaml)

    System.put_env("IXPIPE_HOME", home)

    case opts[:open] do
      nil -> System.delete_env("IXPIPE_WORKFLOW")
      file -> System.put_env("IXPIPE_WORKFLOW", Path.join(home, file))
    end

    port = String.to_integer(System.get_env("QA_PORT", "9340"))

    app =
      Playwright.start_app!(System.get_env("QA_BIN", @release),
        port: port,
        env: Keyword.get(opts, :env, [])
      )

    %{app: app, page: Playwright.connect!(app), home: home}
  end

  def stop(%{app: app, home: home}) do
    Playwright.stop_app(app)
    System.delete_env("IXPIPE_HOME")
    System.delete_env("IXPIPE_WORKFLOW")
    File.rm_rf!(home)
  end

  @doc """
  Writes the window to `<name>.png`, and `expectations` (at most three
  plain-English claims about what the picture shows) to `<name>.json`, in
  the output directory. Returns the PNG's path.
  """
  def capture(page, name, expectations) when length(expectations) in 1..3 do
    dir = out_dir()
    File.mkdir_p!(dir)
    png = Path.join(dir, "#{name}.png")
    File.write!(png, Playwright.screenshot(page))

    File.write!(
      Path.join(dir, "#{name}.json"),
      Jason.encode!(%{name: name, expectations: expectations}, pretty: true)
    )

    png
  end

  @doc "The QA fixtures directory (orders.csv, customers.csv)."
  def fixtures, do: @fixtures

  def out_dir, do: System.get_env("QA_OUT", Path.expand("../qa/.shots", __DIR__))

  # The demo home: sales.yaml joins orders to customers, totals by customer,
  # sorts and writes a CSV.
  defp seed!(home) do
    File.mkdir_p!(home)
    out = Path.join(home, "totals.csv")

    File.write!(Path.join(home, "sales.yaml"), """
    name: sales
    nodes:
      - {id: orders, tool: input_csv, position: {x: 20, y: 30}, config: {path: #{@fixtures}/orders.csv}}
      - {id: customers, tool: input_csv, position: {x: 20, y: 190}, config: {path: #{@fixtures}/customers.csv}}
      - id: joined
        tool: join
        position: {x: 240, y: 110}
        inputs: {left: orders, right: customers}
        config: {on: [customer_id]}
      - id: totals
        tool: summarize
        position: {x: 460, y: 110}
        inputs: {in: joined}
        config: {group_by: [name], aggregates: [{column: amount, op: sum, as: total}]}
      - {id: sorted, tool: sort, position: {x: 680, y: 30}, inputs: {in: totals}, config: {by: [total], desc: true}}
      - {id: out, tool: output_csv, position: {x: 680, y: 190}, inputs: {in: sorted}, config: {path: #{out}}}
    """)

    File.write!(Path.join(home, "split.yaml"), """
    name: split
    nodes:
      - {id: orders, tool: input_csv, position: {x: 20, y: 60}, config: {path: #{@fixtures}/orders.csv}}
      - {id: big, tool: filter, position: {x: 240, y: 60}, inputs: {in: orders}, config: {expr: "amount > 20"}}
      - {id: large, tool: sort, position: {x: 470, y: 10}, inputs: {in: big.true}, config: {by: [amount], desc: true}}
      - {id: small, tool: sort, position: {x: 470, y: 190}, inputs: {in: big.false}, config: {by: [amount]}}
    """)

    File.write!(Path.join(home, "scratch.yaml"), "name: scratch\nnodes: []\n")
  end
end
