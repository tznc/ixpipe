defmodule IxpipeCore.Tools.InputExcel do
  @moduledoc """
  Reads a sheet of an Excel workbook (.xlsx). Config: `path`, optional
  `sheet` (default: the first) and `header` (default true: the first row
  names the columns). Columns of whole numbers become integers, other
  numbers floats, dates dates, and anything else text. An empty sheet is
  one empty text column, `column_1`.
  """
  @behaviour IxpipeCore.Tool

  alias IxpipeCore.{Context, Warnings}

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
        key: "header",
        label: "First row is the header",
        type: :bool,
        optional: true,
        default: true
      }
    ]

  @impl true
  def run(_inputs, %{"path" => path} = config, ctx) do
    package =
      case XlsxReader.open(path) do
        {:ok, package} ->
          package

        {:error, reason} ->
          raise "#{path} can't be opened as an Excel workbook: #{reason}. " <>
                  "Choose an .xlsx file that exists."
      end

    sheets = XlsxReader.sheet_names(package)
    sheet = config["sheet"] || List.first(sheets)

    unless sheet in sheets,
      do: raise("No sheet named #{sheet}. Sheets: #{Enum.join(sheets, ", ")}")

    {:ok, rows} = XlsxReader.sheet(package, sheet, blank_value: nil, empty_rows: true)
    # Kept with their sheet row numbers, so a warning can name a cell.
    rows = rows |> unreadable(ctx) |> Enum.reject(&Enum.all?(&1, fn v -> v == nil end))
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

    table = Context.table(ctx, Enum.zip_with(names, columns, &{&1, column(&2)}))
    Warnings.numbers_as_text(ctx, table)
    table
  end

  # Excel's error values (#DIV/0!, #N/A, …) and cells the reader couldn't
  # convert (#ERROR) become empty, with a warning naming the first.
  @errors ~w(#ERROR #DIV/0! #N/A #NAME? #NULL! #NUM! #REF! #VALUE! #SPILL! #CALC! #GETTING_DATA)
  defp unreadable(rows, ctx) do
    bad =
      for {row, r} <- Enum.with_index(rows, 1),
          {value, c} <- Enum.with_index(row),
          value in @errors,
          do: {value, cell_name(c, r)}

    case bad do
      [] ->
        rows

      [{value, cell} | _] ->
        cells =
          if length(bad) == 1,
            do: "1 cell couldn't be read and is",
            else: "#{length(bad)} cells couldn't be read and are"

        Context.warn(
          ctx,
          "#{cells} empty (#{value} in #{cell}). Fix the formulas in the workbook, or fill the gaps with Data cleansing."
        )

        Enum.map(rows, &Enum.map(&1, fn v -> if v in @errors, do: nil, else: v end))
    end
  end

  # 0-based column, 1-based row: {0, 1} is A1, {27, 3} is AB3.
  defp cell_name(c, r), do: column_letters(c) <> Integer.to_string(r)
  defp column_letters(c) when c < 26, do: <<?A + c>>
  defp column_letters(c), do: column_letters(div(c, 26) - 1) <> <<?A + rem(c, 26)>>

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
