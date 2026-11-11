defmodule AtlasFlowGenerator.Schema.CompositionTest do
  use ExUnit.Case, async: true

  # A neutral pair: a letter is posted, which records a receipt; the receipt's run
  # reports back to the letter (a link) and the letter counts its receipts (a count).
  @letter """
  subflow :letter, subject: :letter do
    run_as "system:post"
    start :create
    initial :post
    state :post do
      effect :post_letter, service: :mail, records: {:receipt, :receipt_of},
        on: [done: :waiting, refused: :stopped]
    end
    state :waiting do
      await :reply, signed: :done, lost: :stopped
      branch to: :done, by: :atlas, when: "entity.open_receipts == 0 and entity.receipts > 1"
    end
    final :done
    final :stopped
  end
  """

  @receipt """
  subflow :receipt, subject: :receipt do
    start :create
    initial :out
    state :out do
      wait_for [:carrier], on: :seen, reset: false, yes: :signed, no: :lost
    end
    final :signed
    final :lost
  end
  """

  @link "link :receipt, to: {:letter, :receipt_of}, field: :reply, states: [signed: :signed, lost: :lost]\n"
  @count "count :receipt, to: {:letter, :receipt_of}, all: :receipts, open: :open_receipts\n"

  describe "a composition compiles to plain data" do
    test "its links and counts, and every subflow in the order listed" do
      c = compose!([@letter, @receipt], [@link, @count])

      assert Enum.map(c.__flows__(), & &1.name) == [:letter, :receipt]

      assert %{
               name: :fixture,
               links: [
                 %{
                   child: :receipt,
                   subject: :letter,
                   relation: :receipt_of,
                   field: :reply,
                   states: [signed: :signed, lost: :lost]
                 }
               ],
               counts: [%{child: :receipt, all: :receipts, open: :open_receipts}]
             } = c.__composition__()

      assert c.__composition__().file =~ ~r/composition_\d+\.ex$/
    end
  end

  # One fixture per rule: each is refused at compile time, in the composition's file,
  # at the line of the link, count or subflows at fault. Line 1 is `subflows`.
  describe "a broken composition does not compile" do
    test "an awaited field that no link or count writes" do
      refused(
        [@letter, @receipt],
        [@count],
        1,
        "awaits reply, which no link or count writes to letter"
      )
    end

    test "an awaited field that two links write" do
      refused(
        [@letter, @receipt],
        [@link, @count, @link],
        4,
        "reply on letter is written by more than one link or count"
      )
    end

    test "a value a link writes that no branch on the parent reads" do
      link = String.replace(@link, "lost: :lost", "lost: :misplaced")

      refused(
        [@letter, @receipt],
        [link, @count],
        2,
        "writes reply misplaced to letter, which no branch"
      )
    end

    test "a field a count writes that no branch on the parent reads" do
      count = String.replace(@count, ":open_receipts", ":pending")

      refused(
        [@letter, @receipt],
        [@link, count],
        3,
        "writes pending to letter, which no branch of a subflow on it reads"
      )
    end

    test "a link state the child subflow does not have" do
      link = String.replace(@link, "lost: :lost", "torn: :lost")
      refused([@letter, @receipt], [link, @count], 2, "subflow receipt has no state torn")
    end

    test "a link from a subflow the composition does not hold" do
      link = String.replace(@link, "link :receipt", "link :parcel")

      refused(
        [@letter, @receipt],
        [link, @count],
        2,
        "link parcel: names no subflow of this composition"
      )
    end

    test "a link to a subject no subflow runs on" do
      link = String.replace(@link, "{:letter,", "{:parcel,")

      refused(
        [@letter, @receipt],
        [@link, @count, link],
        4,
        "link receipt: no subflow runs on parcel"
      )
    end

    test "an effect that records a type no subflow starts on when created" do
      receipt =
        String.replace(
          @receipt,
          "start :create",
          ~s(start :predicate, when: "entity.seen == 'yes'")
        )

      refused(
        [@letter, receipt],
        [@link, @count],
        1,
        "effect post_letter records a receipt, but no subflow starts on receipt"
      )
    end

    test "a field with two writers on one subject type" do
      letter = String.replace(@letter, "service: :mail,", "service: :mail, field: :receipts,")

      refused(
        [letter, @receipt],
        [@link, @count],
        3,
        "receipts on letter has more than one writer: effect post_letter, count receipt"
      )
    end

    test "two subflows that start one run per subject by the same trigger" do
      other =
        "subflow :copy, subject: :receipt do\n  start :create\n  initial :a\n  state :a do\n    wait_for [:carrier], on: :seen, reset: false, yes: :b\n  end\n  final :b\nend\n"

      refused(
        [@letter, @receipt, other],
        [@link, @count],
        1,
        "subflows receipt, copy each start one run per receipt on create"
      )
    end

    test "a listed module without subflows" do
      refused_with(
        [@letter, @receipt],
        "Kernel",
        [@link, @count],
        1,
        "Kernel defines no subflows"
      )
    end
  end

  # Each subflow goes in its own module, compiled first; the composition lists them.
  defp compose!(subflows, entries, extra \\ nil) do
    n = System.unique_integer([:positive])

    modules =
      for {body, i} <- Enum.with_index(subflows) do
        m = :"Elixir.AtlasFlowGenerator.CompositionFixture#{n}.Flow#{i}"
        src = "defmodule #{inspect(m)} do use AtlasFlowGenerator.Schema\n#{body}end\n"
        [{^m, _}] = Code.compile_string(src, "subflows_#{n}_#{i}.ex")
        inspect(m)
      end

    listed = Enum.join(modules ++ List.wrap(extra), ", ")
    module = :"Elixir.AtlasFlowGenerator.CompositionFixture#{n}"

    src =
      "defmodule #{inspect(module)} do use AtlasFlowGenerator.Schema.Composition; defcomposition :fixture do\n" <>
        "subflows [#{listed}]\n" <> Enum.join(entries) <> "end end\n"

    [{^module, _}] = Code.compile_string(src, "composition_#{n}.ex")
    module
  end

  defp refused(subflows, entries, line, message),
    do: refused_with(subflows, nil, entries, line, message)

  defp refused_with(subflows, extra, entries, line, message) do
    error = assert_raise CompileError, fn -> compose!(subflows, entries, extra) end
    assert error.description =~ message
    assert error.file =~ ~r/composition_\d+\.ex$/
    # Fixture line N is file line N + 1 (the defmodule line comes first).
    assert error.line == line + 1,
           "expected line #{line + 1}, got #{error.line}: #{error.description}"

    refute error.description =~ "\n  line ", "more than one problem: #{error.description}"
  end
end
