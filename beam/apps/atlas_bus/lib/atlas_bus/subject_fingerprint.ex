defmodule AtlasBus.SubjectFingerprint do
  @moduledoc "A subject's deciding fields and relation keys, selected by data and digested identically by readers and enforcers."

  def of(fact, spec) do
    AtlasBus.Digest.of_term(%{
      "values" => Map.new(spec["fields"] || [], &{&1, get_in(fact, ["values", &1])}),
      "links" =>
        Map.new(spec["relations"] || [], &{&1, Enum.sort(List.wrap(get_in(fact, ["links", &1])))})
    })
  end
end
