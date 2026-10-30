defmodule IxpipeCore.Config do
  @moduledoc """
  Tool settings as text, for editors: `format/2` shows a config value in an
  input, `parse/2` reads what was typed back. `parse(f, format(f, v))` is
  `{:ok, v}` for every valid value.

  | Type | Text | Value |
  | --- | --- | --- |
  | `:string`, `:path`, `:expr` | trimmed text | the text |
  | `:code` | lines of code | the text, without trailing blank lines |
  | `:list` | `id, amount` | `["id", "amount"]` |
  | `:bool` | `true` / `false` | a boolean |
  | `:choice` | one of `options` | the text |
  | `:integer` | `10` | an integer |
  | `:formulas` | one per line, `name = expression` | `[%{"as", "expr"}]` |
  | `:aggregates` | `sum(amount) as total, count(id) as orders` | `[%{"op", "column", "as"}]` |

  Empty text is `{:ok, nil}` (remove the setting) for an optional field and
  `{:error, "Required"}` otherwise.
  """

  @type type ::
          :string
          | :path
          | :expr
          | :code
          | :list
          | :bool
          | :choice
          | :integer
          | :formulas
          | :aggregates

  @spec format(IxpipeCore.Tool.field(), term()) :: String.t()
  def format(_field, nil), do: ""
  def format(%{type: :list}, values), do: Enum.join(values, ", ")
  def format(%{type: :bool}, value), do: to_string(value)
  def format(%{type: :integer}, value), do: Integer.to_string(value)

  def format(%{type: :formulas}, formulas),
    do: Enum.map_join(formulas, "\n", fn %{"as" => as, "expr" => expr} -> "#{as} = #{expr}" end)

  def format(%{type: :aggregates}, aggregates),
    do:
      Enum.map_join(aggregates, ", ", fn %{"op" => op, "column" => column, "as" => as} ->
        "#{op}(#{column}) as #{as}"
      end)

  def format(_field, value), do: to_string(value)

  @spec parse(IxpipeCore.Tool.field(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def parse(field, text) do
    case String.trim(text) do
      "" -> if field[:optional], do: {:ok, nil}, else: {:error, "Required"}
      # Code keeps its leading indentation.
      _ when field.type == :code -> {:ok, String.trim_trailing(text)}
      text -> parse_text(field, text)
    end
  end

  defp parse_text(%{type: :list}, text) do
    case text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> {:error, "Required"}
      values -> {:ok, values}
    end
  end

  defp parse_text(%{type: :bool}, "true"), do: {:ok, true}
  defp parse_text(%{type: :bool}, "false"), do: {:ok, false}
  defp parse_text(%{type: :bool}, _), do: {:error, "Enter true or false"}

  defp parse_text(%{type: :choice, options: options}, text) do
    if text in options,
      do: {:ok, text},
      else: {:error, "Choose one of: " <> Enum.join(options, ", ")}
  end

  defp parse_text(%{type: :integer}, text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "Enter a whole number"}
    end
  end

  defp parse_text(%{type: :formulas}, text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> collect(fn line ->
      with [as, expr] <- String.split(line, "=", parts: 2),
           {as, expr} when as != "" and expr != "" <- {String.trim(as), String.trim(expr)} do
        {:ok, %{"as" => as, "expr" => expr}}
      else
        _ -> {:error, "Write one formula per line as name = expression"}
      end
    end)
  end

  defp parse_text(%{type: :aggregates}, text) do
    ops = IxpipeCore.Tools.Summarize.ops()

    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> collect(fn item ->
      case Regex.run(~r/^(\w+)\s*\(\s*([^()]+?)\s*\)\s+as\s+(.+)$/i, item) do
        [_, op, column, as] ->
          op = String.downcase(op)

          if op in ops,
            do: {:ok, %{"op" => op, "column" => column, "as" => String.trim(as)}},
            else: {:error, "#{op} is not an aggregate. Use one of: " <> Enum.join(ops, ", ")}

        nil ->
          {:error, "Use op(column) as name, e.g. sum(amount) as total"}
      end
    end)
  end

  defp parse_text(_field, text), do: {:ok, text}

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "Required"}
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
