defmodule IxpipeCore.Tools.Sample do
  @moduledoc "Keeps the first (or last) `n` rows. Config: `n`, optional `from`."
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "n", label: "Rows", type: :integer, hint: "How many rows to keep"},
      %{key: "from", label: "From", type: :choice, options: ["first", "last"], optional: true}
    ]

  @impl true
  def run(%{"in" => t}, %{"n" => n} = config, ctx) do
    case config["from"] do
      "last" ->
        offset = max(Table.count(t) - n, 0)
        Context.sql(ctx, "SELECT * FROM #{Table.ref(t)} LIMIT #{n} OFFSET #{offset}")

      _ ->
        Context.sql(ctx, "SELECT * FROM #{Table.ref(t)} LIMIT #{n}")
    end
  end
end
