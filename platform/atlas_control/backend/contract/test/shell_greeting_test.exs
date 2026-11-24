defmodule AtlasBFFContract.ShellGreetingTest do
  @moduledoc """
  The shell may carry a `greeting` (UC-Atlas-46): the words a client greets its viewer
  with, its name filled in by Control at boot. It is optional, in the model and on the
  boot reply that carries it, so a shell without one is as before.
  """
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Contract

  @schema Contract.__schema__()

  test "the shell model has an optional greeting text" do
    shell = Enum.find(@schema.models, &(&1.name == :shell))
    assert %{type: :string, required: false} = Enum.find(shell.fields, &(&1.name == :greeting))
  end

  test "boot's shell reply may carry it, and needs it not" do
    boot = Enum.find(@schema.protocol, &(&1.name == :boot))
    shell = Enum.find(boot.replies, &(&1.name == :shell))
    assert shell.optional["greeting"] == :string
    refute Map.has_key?(shell.required, "greeting")
  end
end
