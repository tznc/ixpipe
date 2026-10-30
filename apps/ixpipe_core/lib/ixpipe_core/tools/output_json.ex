defmodule IxpipeCore.Tools.OutputJson do
  @moduledoc """
  Writes its input to a JSON file, local or in cloud storage (see
  `IxpipeCore.Cloud`), and passes it through: an array of objects, or with
  `lines` one object per line (NDJSON). Config: `path`, optional `lines`
  and `connection`.
  """
  @behaviour IxpipeCore.Tool

  @impl true
  def inputs, do: ["in"]

  @impl true
  def fields,
    do:
      IxpipeCore.Files.output_fields("JSON", "json", [
        %{
          key: "lines",
          label: "One object per line (NDJSON)",
          type: :bool,
          optional: true,
          default: false
        }
      ])

  @impl true
  def run(%{"in" => t}, config, _ctx),
    do:
      IxpipeCore.Files.write(
        t,
        config,
        if(config["lines"] == true, do: "FORMAT json", else: "FORMAT json, ARRAY true")
      )
end
