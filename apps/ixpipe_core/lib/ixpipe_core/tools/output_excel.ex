defmodule IxpipeCore.Tools.OutputExcel do
  @moduledoc """
  Writes its input to an Excel workbook (.xlsx), a bold header row then the
  values, and passes it through. Config: `path`, optional `sheet` (default
  "Sheet1").
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.DataFrame

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do: [
      %{key: "path", label: "File", type: :path, hint: "Where to write the workbook (.xlsx)"},
      %{key: "sheet", label: "Sheet", type: :string, optional: true, hint: "Default: Sheet1"}
    ]

  @impl true
  def run(%{"in" => df}, %{"path" => path} = config) do
    names = DataFrame.names(df)
    columns = DataFrame.to_columns(df)
    header = Enum.map(names, &[&1, bold: true])

    rows =
      case names do
        [] -> []
        _ -> Enum.zip_with(Enum.map(names, &columns[&1]), &Enum.map(&1, fn v -> cell(v) end))
      end

    sheet = %Elixlsx.Sheet{name: config["sheet"] || "Sheet1", rows: [header | rows]}
    {:ok, _} = Elixlsx.write_to(%Elixlsx.Workbook{sheets: [sheet]}, String.to_charlist(path))
    df
  end

  defp cell(%Date{} = d), do: [{Date.to_erl(d), {0, 0, 0}}, yyyymmdd: true]
  defp cell(%NaiveDateTime{} = d), do: [NaiveDateTime.to_erl(d), datetime: true]
  defp cell(value) when is_boolean(value), do: to_string(value)
  defp cell(value), do: value
end
