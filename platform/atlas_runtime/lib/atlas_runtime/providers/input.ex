defmodule AtlasRuntime.Agent.Input do
  @moduledoc "Exact immutable literal input contract, independent of workflow kinds."
  @identity ~w(environment worker turn attempt interaction)

  def validate_identity(identity) do
    if is_map(identity) and Enum.sort(Map.keys(identity)) == Enum.sort(@identity) and
         Enum.all?(@identity, &identifier?(identity[&1])),
       do: :ok,
       else: {:error, :invalid_identity}
  end

  def validate(request) when is_map(request) do
    with :ok <- validate_identity(Map.drop(request, ["body", "mode"])),
         true <- request["mode"] == "queued_guidance",
         body when is_binary(body) <- request["body"],
         true <- String.valid?(body) and byte_size(body) > 0,
         true <- byte_size(JSON.encode!(request)) <= 24_576 do
      :ok
    else
      _ -> {:error, :invalid_input}
    end
  end

  def validate(_), do: {:error, :invalid_input}

  def valid_evidence?(%{"identity" => identity} = evidence, identity) do
    validate_identity(identity) == :ok and
      Enum.sort(Map.keys(evidence)) == ~w(admission_id consumption_id identity stage) and
      identifier?(evidence["admission_id"]) and
      ((evidence["stage"] == "admitted" and evidence["consumption_id"] == nil) or
         (evidence["stage"] == "consumed" and identifier?(evidence["consumption_id"]))) and
      byte_size(JSON.encode!(evidence)) <= 8_192
  rescue
    _ -> false
  end

  def valid_evidence?(_, _), do: false

  def identifier?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)
end
