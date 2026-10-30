defmodule IxpipeCore.Files do
  @moduledoc false
  # What the CSV, Parquet and JSON tools share: one file, a folder (every
  # file of the format in it) or a wildcard pattern, local or in cloud
  # storage (`IxpipeCore.Cloud`), read through DuckDB and unioned by column
  # name; and writing a table to one file with COPY.

  alias IxpipeCore.{Cloud, Context, Table}
  import IxpipeCore.Duck, only: [literal: 1]

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

  @doc "Reads `config`'s path with DuckDB's `reader` (`read_csv`, …) as the node's table."
  def read(ctx, reader, ext, %{"path" => path} = config) do
    Cloud.prepare!(ctx.db, path, config)
    source = source(path, ext)

    options =
      ["union_by_name = true"] ++ if config["filename"] == true, do: ["filename = true"], else: []

    try do
      Context.sql(ctx, "SELECT * FROM #{reader}(#{literal(source)}, #{Enum.join(options, ", ")})")
    rescue
      e in RuntimeError ->
        if e.message =~ "No files found that match the pattern",
          do:
            raise(
              "No files match #{source}. Check the path, or choose a file or folder that has some."
            ),
          else: reraise(e, __STACKTRACE__)
    end
  end

  @doc "Writes `table` to `config`'s path with COPY `options`, passing it through."
  def write(%Table{} = table, %{"path" => path} = config, options) do
    Cloud.prepare!(table.db, path, config)
    Table.exec!(table.db, "COPY #{Table.ref(table)} TO #{literal(path)} (#{options})")
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
