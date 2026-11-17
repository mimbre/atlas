defmodule AtlasFacts.RelaHttpIfMatchTest do
  @moduledoc """
  The rela HTTP client's half of the fenced write: a change sends the version it was
  given as `If-Match`, and rela's 412 answer is a version mismatch, which is what makes
  Facts re-read and compare `was`. That rela honours `If-Match` on PATCH is an outside
  assumption, kept for the pinned rela. Asserted: the recorded request, the result tag.
  """
  use ExUnit.Case, async: true

  alias AtlasFacts.Rela.Http
  alias AtlasFacts.StubHttp

  test "5. a change sends if-match with the given version" do
    stub = StubHttp.start(fn _request -> {200, "{}"} end)

    assert {:ok, []} = Http.change(stub.url, "widgets", "W-1", %{"x" => 1}, "v7", %{})

    assert [%{method: "PATCH", path: "/widgets/W-1", headers: %{"if-match" => "v7"}}] =
             StubHttp.requests(stub)
  end

  test "6. a 412 answer is a version mismatch" do
    stub = StubHttp.start(fn _request -> {412, "{}"} end)

    assert {:error, :version_mismatch} =
             Http.change(stub.url, "widgets", "W-1", %{"x" => 1}, "v7", %{})

    assert [%{method: "PATCH", headers: %{"if-match" => "v7"}}] = StubHttp.requests(stub)
  end
end
