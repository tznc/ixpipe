defmodule IxpipeCore.Tools.JoinMultiple do
  @moduledoc """
  Joins two to four inputs on the key columns `on`, which every input
  has, as Alteryx's Join Multiple. `in1` and `in2` are required; `in3` and
  `in4` are optional ports. `how` is `outer` (default: every key from any
  input, nulls where an input has none) or `inner` (only keys every input
  has). The keys come first, then each input's other columns in port
  order; a name an earlier input has gets the suffix `_in<n>`.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Table}
  import IxpipeCore.Duck, only: [ident: 1]

  @ports ~w(in1 in2 in3 in4)

  @impl true
  def inputs, do: @ports

  @impl true
  def optional_inputs, do: ["in3", "in4"]

  @impl true
  def fields,
    do: [
      %{key: "on", label: "Join on", type: :list, hint: "Columns every input shares"},
      %{
        key: "how",
        label: "Join type",
        type: :choice,
        options: ["outer", "inner"],
        default: "outer",
        optional: true
      }
    ]

  @impl true
  def run(inputs, %{"on" => on} = config, ctx) do
    tables = for port <- @ports, t = inputs[port], do: {port, t}

    for {port, t} <- tables,
        k <- on,
        k not in Table.columns(t),
        do: raise("#{port} has no column #{k}. Join on columns every input has.")

    join = if config["how"] == "inner", do: "JOIN", else: "FULL JOIN"
    keys = Enum.map_join(on, ", ", &ident/1)

    {columns, _seen} =
      Enum.reduce(tables, {[], on}, fn {port, t}, {acc, seen} ->
        alias_ = ident(port)

        cols =
          for c <- Table.columns(t), c not in on do
            as = if c in seen, do: c <> "_" <> port, else: c
            {"#{alias_}.#{ident(c)} AS #{ident(as)}", as}
          end

        {acc ++ Enum.map(cols, &elem(&1, 0)), seen ++ Enum.map(cols, &elem(&1, 1))}
      end)

    [{first, t1} | rest] = tables

    from =
      Enum.reduce(rest, "#{Table.ref(t1)} #{ident(first)}", fn {port, t}, acc ->
        "#{acc} #{join} #{Table.ref(t)} #{ident(port)} USING (#{keys})"
      end)

    Context.sql(ctx, "SELECT #{Enum.join([keys | columns], ", ")} FROM #{from}")
  end
end
