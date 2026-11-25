defmodule AtlasCode.ClosingKeywordsTest do
  use ExUnit.Case, async: true
  alias AtlasCode.ClosingKeywords

  test "every keyword form, in any case, before every reference form is defused" do
    for keyword <- ~w(close closes closed fix fixes fixed resolve resolves resolved),
        keyword <- [keyword, String.upcase(keyword), String.capitalize(keyword)],
        colon <- ["", ":"],
        reference <- [
          "#12",
          "owner/repo#3",
          "https://github.com/o/r/issues/4",
          "https://github.com/o/r/pull/5"
        ] do
      text = "#{keyword}#{colon} #{reference}"
      safe = ClosingKeywords.defuse(text)
      assert safe == "#{keyword}#{colon} (#{reference})"
      refute ClosingKeywords.closing?(safe)
    end
  end

  test "text without a closing reference, or already defused, is left as it is" do
    for text <- [
          "see #12",
          "prefixes #3",
          "fixed the typo",
          "fixes (#12)",
          "Fixes#12",
          "closes ticket #1"
        ],
        do: assert(ClosingKeywords.defuse(text) == text)

    assert ClosingKeywords.defuse("closed #512/#514") |> ClosingKeywords.defuse() ==
             "closed (#512/#514)"
  end

  test "several references in one text are each defused" do
    assert ClosingKeywords.defuse("fixes #1, closes #2 and see #3\nResolved\t#4") ==
             "fixes (#1), closes (#2) and see #3\nResolved\t(#4)"
  end
end
