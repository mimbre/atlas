defmodule AtlasTui.ChoiceInputTest do
  use ExUnit.Case, async: true
  alias AtlasTui.{Blocks, Interactions, Keys, Model}

  defp ready(extra \\ false) do
    path = "/k/decision/D-private"

    pairs =
      [{"0", "files"}, {"1", "files"}, {"2", "memory"}, {"3", "decline"}] ++
        if(extra, do: [{"10", "ten"}], else: [])

    actions =
      for {key, id} <- pairs do
        %{
          "id" => "answer-" <> key,
          "type" => "console_action",
          "props" => %{
            "label" => id,
            "keys" => [key],
            "available" => true,
            "operation" => %{
              "name" => "invoke",
              "call" => %{
                "endpoint" => "answer",
                "params" => %{
                  "kind" => "decision",
                  "key" => "D-private",
                  "answer" => "option-exact-revision-" <> id
                }
              }
            },
            "scope" => %{"page" => path, "revision" => "offer-v1", "context" => "browse"}
          }
        }
      end

    page = %{
      "path" => path,
      "actions_revision" => "offer-v1",
      "blocks" => actions,
      "markup" => [
        %{
          "kind" => "legend",
          "start" => "answer-0",
          "end" => List.last(actions)["id"],
          "props" => %{"title" => "Answers", "context" => "browse"}
        }
      ]
    }

    model = Model.new("test")
    model = %{model | path: path, connected: true, console: %{model.console | phase: :ready}}
    {model, _} = Interactions.install(model, page)
    assert model.console.action_error == nil
    model
  end

  test "digit graphemes invoke only supplied semantic calls; zero and one are identical" do
    model = ready()
    assert {[{:char, "0"}, {:char, "1"}, {:char, "2"}, {:char, "3"}], ""} = Keys.parse("0123")
    effects = for key <- ~w(0 1 2 3), do: elem(Model.key(model, {:char, key}), 1)
    assert Enum.at(effects, 0) == Enum.at(effects, 1)

    assert [
             {:send,
              %{
                "op" => "submit",
                "params" => %{"answer" => "option-exact-revision-memory"},
                "values" => %{}
              }}
           ] = Enum.at(effects, 2)

    assert [{:send, %{"params" => %{"answer" => "option-exact-revision-decline"}}}] =
             Enum.at(effects, 3)

    for key <- ~w(4 9), do: assert({^model, []} = Model.key(model, {:char, key}))
  end

  test "the same digits remain literal text while editing" do
    model = ready()
    input = %Blocks.Input{name: "title", label: "Title", kind: "text", value: ""}

    model = %{
      model
      | blocks: [%Blocks.Form{title: "Edit", inputs: [input], submit_label: "Save"}],
        focus: 0,
        values: %{"title" => ""}
    }

    for key <- ~w(0 1 2 3) do
      {edited, []} = Model.key(model, {:char, key})
      assert edited.values["title"] == key
    end
  end

  # A decline is given with a note: its key opens this form, as Control serves it. The
  # note's bytes and then Ctrl+S (byte 19) as a terminal sends them submit the note. The
  # terminal itself must pass byte 19 through (`stty -ixon`, as `bin/atlas tui` sets);
  # with flow control on, the tty takes it as XOFF and the TUI never sees it.
  test "a decline's note form submits the typed note on Ctrl+S" do
    call = %{
      "endpoint" => "answer",
      "params" => %{"kind" => "decision", "key" => "D-private", "answer" => "option-r-decline"}
    }

    form = %{
      "op" => "page",
      "path" => "/k/decision/D-private/answer/option-r-decline",
      "title" => "Do neither D-private",
      "back" => "/k/decision/D-private",
      "reason" => "open",
      "blocks" => [
        %{
          "type" => "form",
          "props" => %{
            "title" => "Do neither D-private",
            "submit_label" => "Do neither",
            "submit_to" => call,
            "cancel_to" => "/k/decision/D-private",
            "inputs" => [
              %{"name" => "note", "label" => "Note", "kind" => "multiline", "required" => true}
            ]
          }
        }
      ]
    }

    model = AtlasTui.ConsoleProjectionFixture.model(form)
    note = "Neither storage rule fits."
    {keys, ""} = Keys.parse(note <> <<19>>)
    assert List.last(keys) == :ctrl_s

    {typed, effects} =
      Enum.reduce(keys, {model, []}, fn key, {model, _} -> Model.key(model, key) end)

    assert typed.values["note"] == note

    assert [{:send, %{"op" => "submit", "values" => %{"note" => ^note}} = sent}] = effects
    assert Map.take(sent, ~w(endpoint params)) == call
  end

  test "multi-digit projected shortcuts wait for explicit Enter and reject out-of-range numbers" do
    model = ready(true)
    {pending, []} = Model.key(model, {:char, "1"})
    {pending, []} = Model.key(pending, {:char, "0"})
    assert pending.console.key_buffer == "10"

    {_, [{:send, %{"params" => %{"answer" => "option-exact-revision-ten"}}}]} =
      Model.key(pending, :enter)

    {pending, []} = Model.key(model, {:char, "9"})
    {pending, []} = Model.key(pending, {:char, "9"})
    {cleared, []} = Model.key(pending, :enter)
    assert cleared.console.key_buffer == ""
    {pending, []} = Model.key(model, {:char, "0"})
    {cleared, []} = Model.key(pending, :esc)
    assert cleared.console.key_buffer == ""
  end

  # A decision as Control projects it: its single choice (the recommended option first,
  # the decline given with a note) and an action per key; a decline's key opens its note
  # form. The list under it takes Up, Down and Enter on any other page.
  defp decision do
    path = "/k/decision/D-private"
    note_form = path <> "/answer/option-r-decline"

    call = fn id ->
      %{
        "endpoint" => "answer",
        "params" => %{"kind" => "decision", "key" => "D-private", "answer" => "option-r-" <> id}
      }
    end

    option = fn id, key, extra ->
      Map.merge(
        %{
          "id" => id,
          "text" => "Use " <> id,
          "details" => "Details of " <> id,
          "effect" => "adopt",
          "rule" => "Store examples in " <> id <> ".",
          "consequences" => "Then " <> id <> " holds them.",
          "answer" => call.(id),
          "shortcut" => key
        },
        extra
      )
    end

    choice = %{
      "id" => "choice",
      "type" => "single_choice",
      "props" => %{
        "question" => "How do we store examples?",
        "rationale" => "Files need nothing to run.",
        "recommended" => "files",
        "revision" => "rev-1",
        "instructions" => "How do we store examples?\n0 selects recommended choice 1.",
        "options" => [
          option.("files", "1", %{}),
          option.("memory", "2", %{}),
          option.("decline", "3", %{"effect" => "decline", "note" => true})
        ]
      }
    }

    operation = fn
      "decline" -> %{"name" => "open", "to" => note_form}
      id -> %{"name" => "invoke", "call" => call.(id)}
    end

    rows = %{
      "id" => "list",
      "type" => "list",
      "props" => %{
        "title" => "Related",
        "rows" => [
          %{"id" => "W-01", "label" => "A widget", "to" => "/k/widget/W-01"},
          %{"id" => "W-02", "label" => "Another", "to" => "/k/widget/W-02"}
        ]
      }
    }

    page = %{
      "op" => "page",
      "path" => path,
      "title" => "D-private",
      "reason" => "open",
      "blocks" => [choice, rows]
    }

    projected = AtlasTui.ConsoleProjectionFixture.project(page)
    scope = %{"page" => path, "revision" => projected["actions_revision"], "context" => "browse"}

    answers =
      for {key, id} <- [{"0", "files"}, {"1", "files"}, {"2", "memory"}, {"3", "decline"}],
          do: %{
            "id" => "answer-" <> key,
            "type" => "console_action",
            "props" => %{
              "label" => id,
              "keys" => [key],
              "available" => true,
              "operation" => operation.(id),
              "scope" => scope
            }
          }

    legend = %{
      "kind" => "legend",
      "start" => "answer-0",
      "end" => "answer-3",
      "props" => %{"title" => "Answers", "context" => "browse"}
    }

    message =
      projected
      |> Map.update!("blocks", &(&1 ++ answers))
      |> Map.update!("markup", &(&1 ++ [legend]))

    {AtlasTui.ConsoleProjectionFixture.projected(page, message), note_form}
  end

  defp screen(model, width),
    do: AtlasTui.View.render(model, width, 60, 30) |> AtlasTui.View.plain()

  defp effects(model, keys) do
    Enum.reduce(keys, {model, []}, fn key, {model, _} -> Model.key(model, key) end)
  end

  test "the arrows move the selection from the recommended option, within the options" do
    {model, _} = decision()
    assert model.choice == nil
    assert screen(model, 100) =~ "Store examples in files."

    {down, []} = Model.key(model, :down)
    assert down.choice == "memory"
    assert down.selected == model.selected
    assert screen(down, 100) =~ "Store examples in memory."
    refute screen(down, 100) =~ "Store examples in files."

    {last, []} = effects(down, [:down, :down, :down])
    assert last.choice == "decline"
    {first, []} = effects(last, [:up, :up, :up, :up])
    assert first.choice == "files"
  end

  test "Enter answers the selected option with the call its own key sends" do
    {model, _} = decision()
    {_, by_one} = Model.key(model, {:char, "1"})
    {_, by_zero} = Model.key(model, {:char, "0"})
    assert [{:send, %{"params" => %{"answer" => "option-r-files"}}}] = by_one
    assert Model.key(model, :enter) |> elem(1) == by_one
    assert by_zero == by_one

    {_, by_two} = Model.key(model, {:char, "2"})
    assert [{:send, %{"params" => %{"answer" => "option-r-memory"}}}] = by_two
    assert effects(model, [:down, :enter]) |> elem(1) == by_two
  end

  test "Enter on a decline asks its note first, as its key does" do
    {model, note_form} = decision()
    {by_key, by_three} = Model.key(model, {:char, "3"})
    {by_enter, by_arrows} = effects(model, [:down, :down, :enter])

    assert [{:send, %{"op" => "open", "to" => ^note_form}}] = by_three
    assert by_arrows == by_three
    assert by_enter.console.expected == note_form and by_key.console.expected == note_form
  end

  test "a narrow panel drops the labels before it cuts an option's text" do
    {model, _} = decision()
    row = fn screen -> screen |> String.split("\n") |> Enum.find(&(&1 =~ "Use files")) end
    assert row.(screen(model, 100)) =~ "recommended"

    narrow = screen(model, 30)
    assert row.(narrow) =~ "Use files"
    refute row.(narrow) =~ "recommended"
    assert narrow =~ "Use memory" and narrow =~ "Use decline"
    assert narrow =~ "Store examples" and narrow =~ "in files."

    for width <- [1, 5, 12, 20], do: assert(is_binary(screen(model, width)))
  end
end
