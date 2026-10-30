defmodule IxpipeCore.Tools.InputExcel do
  @moduledoc """
  Reads a sheet of an Excel workbook (.xlsx). Config: `path`, optional
  `sheet` (default: the first) and `header` (default true: the first row
  names the columns). Columns of whole numbers become integers, other
  numbers floats, dates dates, and anything else text.
  """
  @behaviour IxpipeCore.Tool

  alias Explorer.{DataFrame, Series}

  @impl true
  def inputs, do: []

  @impl true
  def fields,
    do: [
      %{
        key: "path",
        label: "File",
        type: :path,
        hint: "An Excel workbook (.xlsx) on this computer"
      },
      %{
        key: "sheet",
        label: "Sheet",
        type: :string,
        optional: true,
        hint: "Leave empty for the first sheet"
      },
      %{key: "header", label: "First row is the header", type: :bool, optional: true}
    ]

  @impl true
  def run(_inputs, %{"path" => path} = config) do
    {:ok, package} = XlsxReader.open(path)
    sheets = XlsxReader.sheet_names(package)
    sheet = config["sheet"] || List.first(sheets)

    unless sheet in sheets,
      do: raise("No sheet named #{sheet}. Sheets: #{Enum.join(sheets, ", ")}")

    {:ok, rows} = XlsxReader.sheet(package, sheet, blank_value: nil, empty_rows: false)
    width = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)
    rows = Enum.map(rows, &(&1 ++ List.duplicate(nil, width - length(&1))))

    {names, rows} =
      case {Map.get(config, "header", true), rows} do
        {false, rows} -> {generated(width), rows}
        {_, [header | rows]} -> {column_names(header), rows}
        {_, []} -> {[], []}
      end

    columns =
      if rows == [], do: List.duplicate([], length(names)), else: Enum.zip_with(rows, & &1)

    names
    |> Enum.zip(columns)
    |> Enum.map(fn {name, values} -> {name, series(values)} end)
    |> DataFrame.new()
  end

  defp generated(width), do: for(i <- 1..width//1, do: "column_#{i}")

  # Blank or repeated headers become column_N, N being the column's position.
  defp column_names(header) do
    header
    |> Enum.with_index(1)
    |> Enum.map_reduce(MapSet.new(), fn {cell, i}, seen ->
      name = if cell in [nil, ""], do: nil, else: to_string(cell)
      name = if name == nil or name in seen, do: "column_#{i}", else: name
      {name, MapSet.put(seen, name)}
    end)
    |> elem(0)
  end

  defp series(values) do
    present = Enum.reject(values, &is_nil/1)

    cond do
      present == [] ->
        Series.from_list(values, dtype: :string)

      Enum.all?(present, &(is_number(&1) and &1 == trunc(&1))) ->
        Series.from_list(Enum.map(values, &(&1 && trunc(&1))))

      Enum.all?(present, &is_number/1) ->
        Series.from_list(Enum.map(values, &(&1 && &1 * 1.0)))

      Enum.all?(present, &match?(%Date{}, &1)) ->
        Series.from_list(values)

      Enum.all?(present, &match?(%NaiveDateTime{}, &1)) ->
        if Enum.all?(present, &(NaiveDateTime.to_time(&1) == ~T[00:00:00])),
          do: Series.from_list(Enum.map(values, &(&1 && NaiveDateTime.to_date(&1)))),
          else: Series.from_list(values)

      true ->
        Series.from_list(Enum.map(values, &(&1 && to_string(&1))), dtype: :string)
    end
  end
end
