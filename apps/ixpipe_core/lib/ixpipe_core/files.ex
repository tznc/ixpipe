defmodule IxpipeCore.Files do
  @moduledoc false
  # What the CSV, Parquet and JSON tools share: one file, a folder (every
  # file of the format in it) or a wildcard pattern, local or in cloud
  # storage (`IxpipeCore.Cloud`), read through DuckDB and unioned by column
  # name; and writing a table to one file with COPY.

  alias IxpipeCore.{Cloud, Context, Table}
  import IxpipeCore.Duck, only: [ident: 1, literal: 1]

  @doc "The settings of a tool that reads `format` files (`ext` is their extension)."
  def input_fields(name, ext),
    do: [
      %{
        key: "path",
        label: "File",
        type: :path,
        accept: [ext],
        hint:
          "A #{name} file, a folder or a pattern like data/*.#{ext}; s3://, gs:// and az:// too"
      },
      %{
        key: "filename",
        label: "Add a file name column",
        type: :bool,
        optional: true,
        default: false
      },
      Cloud.connection_field()
    ]

  @doc "The settings of a tool that writes a `format` file, then `extra`."
  def output_fields(name, ext, extra \\ []),
    do:
      [
        %{
          key: "path",
          label: "File",
          type: :path,
          accept: [ext],
          save: true,
          hint: "Where to write the #{name} file; s3://, gs:// and az:// too"
        }
      ] ++ extra ++ [Cloud.connection_field()]

  @doc """
  Reads `config`'s path with DuckDB's `reader` (`read_csv`, …) as the
  node's table. With `rejects: true` (CSV), rows that fail to parse are
  skipped with a warning naming the first, and its file when the path
  picks several.
  """
  def read(ctx, reader, ext, %{"path" => path} = config, opts \\ []) do
    Cloud.prepare!(ctx.db, path, config)
    source = source(path, ext)
    rejects? = Keyword.get(opts, :rejects, false)

    filename = if config["filename"] == true, do: ["filename = true"], else: []

    try do
      if rejects?,
        do: read_rejecting(ctx, reader, source, filename),
        else:
          Context.sql(
            ctx,
            "SELECT * FROM #{reader}(#{literal(source)}, #{Enum.join(["union_by_name = true" | filename], ", ")})"
          )
    rescue
      e in RuntimeError ->
        if e.message =~ "No files found that match the pattern",
          do: no_files!(source),
          else: reraise(e, __STACKTRACE__)
    end
  end

  # One file that isn't there says so; a folder or pattern that picks
  # nothing says that.
  defp no_files!(source) do
    if String.contains?(source, ["*", "?", "["]),
      do:
        raise(
          "No files match #{source}. Check the path, or choose a file or folder that has some."
        ),
      else: raise("The file #{source} doesn't exist. Choose a file that does.")
  end

  # DuckDB can't keep rejected rows while it unions files by name, so each
  # file is read on its own and the reads are unioned by name instead.
  defp read_rejecting(ctx, reader, source, filename) do
    %{rows: files} =
      Table.query!(ctx.db, "SELECT file FROM glob(#{literal(source)}) ORDER BY file")

    if files == [], do: no_files!(source)

    options =
      Enum.join(
        filename ++
          [
            "store_rejects = true",
            "rejects_table = 'ixpipe_rejects'",
            "rejects_scan = 'ixpipe_rejects_scan'"
          ],
        ", "
      )

    select =
      Enum.map_join(files, " UNION ALL BY NAME ", fn [file] ->
        "SELECT * FROM #{reader}(#{literal(file)}, #{options})"
      end)

    name = Context.name(ctx, nil)
    rejects = name <> ".__rejects"
    several? = length(files) > 1

    # DuckDB keeps rejected rows in a temporary table of the connection that
    # read the files, so copy them out in the same call.
    Table.exec!(ctx.db, """
    CREATE OR REPLACE TABLE #{ident(name)} AS #{select};
    CREATE OR REPLACE TABLE #{ident(rejects)} AS
      SELECT s.file_path AS file, r.line,
        first(r.error_message ORDER BY r.byte_position) AS error_message
      FROM ixpipe_rejects r JOIN ixpipe_rejects_scan s USING (scan_id, file_id)
      GROUP BY s.file_path, r.line ORDER BY s.file_path, r.line;
    """)

    %{rows: rows} =
      Table.query!(ctx.db, "SELECT file, line, error_message FROM #{ident(rejects)}")

    Table.exec!(ctx.db, "DROP TABLE #{ident(rejects)}")

    case rows do
      [] ->
        :ok

      [[file, line, error] | _] ->
        {count, them, was} =
          if length(rows) == 1,
            do: {"1 row", "it", "was"},
            else: {"#{length(rows)} rows", "them", "were"}

        where = if several?, do: "#{Path.basename(file)} line #{line}", else: "line #{line}"

        Context.warn(
          ctx,
          "#{count} couldn't be read and #{was} skipped (#{where}: #{first_line(error)}). " <>
            "Fix #{them} in the file, or check its delimiter and quoting."
        )
    end

    %Table{db: ctx.db, name: name}
  end

  defp first_line(error),
    do: error |> String.split("\n", trim: true) |> List.first("") |> String.trim_trailing(".")

  @doc """
  Writes `table` to `config`'s path with COPY `options`, saying how many
  rows went where, and passes it through.
  """
  def write(%Table{} = table, %{"path" => path} = config, options, ctx) do
    Cloud.prepare!(table.db, path, config)
    Table.exec!(table.db, "COPY #{Table.ref(table)} TO #{literal(path)} (#{options})")
    Context.info(ctx, "Wrote #{IxpipeCore.plural(Table.count(table), "row")} to #{path}.")
    table
  end

  # A local folder, or a cloud path ending in /, means every file of the
  # format in it.
  defp source(path, ext) do
    cond do
      Cloud.kind(path) && String.ends_with?(path, "/") -> path <> "*.#{ext}"
      Cloud.kind(path) == nil and File.dir?(path) -> Path.join(path, "*.#{ext}")
      true -> path
    end
  end
end
