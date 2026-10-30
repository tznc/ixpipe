defmodule IxpipeCore.Tools.InputExcel do
  @moduledoc """
  Reads a sheet of an Excel workbook (.xlsx). Config: `path`, optional
  `sheet` (default: the first), `range` (cells like `B3:F20`, or `B3:F` to
  the sheet's end; default: the whole sheet) and `header` (default true:
  the first row names the columns). Blank rows are left out. Columns of whole numbers become integers, other
  numbers floats, dates dates, and anything else text. An empty sheet is
  one empty text column, `column_1`.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.Context

  @impl true
  def inputs, do: []

  @impl true
  def fields,
    do: [
      %{
        key: "path",
        accept: ["xlsx"],
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
      %{
        key: "range",
        label: "Cell range",
        type: :string,
        optional: true,
        hint: "e.g. B3:F20, or B3:F to the end; empty for the whole sheet"
      },
      %{
        key: "header",
        label: "First row is the header",
        type: :bool,
        optional: true,
        default: true
      }
    ]

  @impl true
  def run(_inputs, %{"path" => path} = config, ctx) do
    {:ok, package} = XlsxReader.open(path)
    sheets = XlsxReader.sheet_names(package)
    sheet = config["sheet"] || List.first(sheets)

    unless sheet in sheets,
      do: raise("No sheet named #{sheet}. Sheets: #{Enum.join(sheets, ", ")}")

    range = range!(config["range"])
    {:ok, rows} = XlsxReader.sheet(package, sheet, blank_value: nil, empty_rows: range != nil)
    rows = rows |> cells(range) |> Enum.reject(fn row -> Enum.all?(row, &(&1 in [nil, ""])) end)
    width = rows |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)
    rows = Enum.map(rows, &(&1 ++ List.duplicate(nil, width - length(&1))))

    {names, rows} =
      case {Map.get(config, "header", true), rows} do
        {false, rows} -> {generated(width), rows}
        {_, [header | rows]} -> {column_names(header), rows}
        {_, []} -> {[], []}
      end

    # An empty sheet still needs a column: DuckDB tables have at least one.
    names =
      case names do
        [] -> generated(1)
        names -> names
      end

    columns =
      if rows == [], do: List.duplicate([], length(names)), else: Enum.zip_with(rows, & &1)

    Context.table(ctx, Enum.zip_with(names, columns, &{&1, column(&2)}))
  end

  @doc "Suggested values for a setting: the workbook's sheets for `sheet`."
  @impl true
  def suggestions("sheet", %{"path" => path}) when is_binary(path) do
    with true <- File.regular?(path),
         {:ok, package} <- XlsxReader.open(path) do
      XlsxReader.sheet_names(package)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  def suggestions(_key, _config), do: []

  # {first column, first row, last column, last row}, 0-based; nil for no end.
  defp range!(nil), do: nil

  defp range!(text) do
    case Regex.run(~r/^([A-Z]+)(\d+)?(?::([A-Z]+)(\d+)?)?$/, String.upcase(String.trim(text))) do
      [_, c1 | rest] ->
        [r1, c2, r2] = rest ++ List.duplicate("", 3 - length(rest))
        {col_index(c1), row(r1) || 0, if(c2 != "", do: col_index(c2)), row(r2)}

      nil ->
        raise "#{text} isn't a cell range. Write one like A1:D20, or B3:D to read to the end."
    end
  end

  defp col_index(letters),
    do: letters |> String.to_charlist() |> Enum.reduce(0, &(&2 * 26 + &1 - ?A + 1)) |> Kernel.-(1)

  defp row(""), do: nil
  defp row(digits), do: String.to_integer(digits) - 1

  defp cells(rows, nil), do: rows

  defp cells(rows, {c1, r1, c2, r2}) do
    rows
    |> Enum.drop(r1)
    |> then(&if(r2, do: Enum.take(&1, r2 - r1 + 1), else: &1))
    |> Enum.map(fn row ->
      row = Enum.drop(row, c1)
      if c2, do: Enum.take(row ++ List.duplicate(nil, c2 - c1 + 1), c2 - c1 + 1), else: row
    end)
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

  defp column(values) do
    present = Enum.reject(values, &is_nil/1)

    cond do
      present == [] ->
        values

      Enum.all?(present, &(is_number(&1) and &1 == trunc(&1))) ->
        Enum.map(values, &(&1 && trunc(&1)))

      Enum.all?(present, &is_number/1) ->
        Enum.map(values, &(&1 && &1 * 1.0))

      Enum.all?(present, &match?(%Date{}, &1)) ->
        values

      Enum.all?(present, &match?(%NaiveDateTime{}, &1)) ->
        if Enum.all?(present, &(NaiveDateTime.to_time(&1) == ~T[00:00:00])),
          do: Enum.map(values, &(&1 && NaiveDateTime.to_date(&1))),
          else: values

      true ->
        Enum.map(values, &(&1 && to_string(&1)))
    end
  end
end
