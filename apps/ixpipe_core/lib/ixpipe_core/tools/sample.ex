defmodule IxpipeCore.Tools.Sample do
  @moduledoc "Keeps the first (or last) `n` rows. Config: `n`, optional `from`."
  @behaviour IxpipeCore.Tool

  alias Explorer.DataFrame

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "n", label: "Rows", type: :integer, hint: "How many rows to keep"},
      %{key: "from", label: "From", type: :choice, options: ["first", "last"], optional: true}
    ]

  @impl true
  def run(%{"in" => df}, %{"n" => n} = config) do
    case config["from"] do
      "last" -> DataFrame.tail(df, n)
      _ -> DataFrame.head(df, n)
    end
  end
end
