# The steps of the page freshness proof, required by proof.exs once the e2e helpers it
# names (AtlasE2E.Scenario, AtlasE2E.Tui, PageFreshness.*) are loaded into the core's node.
import ExUnit.Assertions
import AtlasE2E.Scenario

[dir] = System.argv()
proof = dir |> Path.join("proof.json") |> File.read!() |> JSON.decode!()
root = proof["root"]

alias AtlasE2E.Tui
alias PageFreshness.{ControlTime, CoreLog, FlowTime, Sessions}

instance = %{root: root, dir: dir, env: Enum.map(proof["env"], &List.to_tuple/1)}
socket = proof["socket"]
user = "melle"
CoreLog.start()

# The keys of the rows of the list on screen, in order, and which is selected (`›`).
rows = fn tui, keys ->
  for [_, mark, key] <- Regex.scan(~r/^ (›| ) (\S+)  /m, settled(tui)),
      key in keys,
      do: %{key: key, selected: mark == "›"}
end

selected = fn rows -> Enum.find_index(rows, & &1.selected) end

try do
  # The TUIs' user, and the agent Flow hands an accepted decision to, exist first.
  {person, _} = atlas_json(instance, ["put", "person", "--name", "Melle"])
  assert person["key"] == user
  {agent, _} = atlas_json(instance, ["put", "agent", "--name", "Coordinator"])
  assert agent["key"] == "coordinator"

  t1 = Tui.start(instance, socket, "tui1", "TUI 1")
  ready(t1, 120_000)
  a = Sessions.new(user, [], 10_000)
  t2 = Tui.start(instance, socket, "tui2", "TUI 2")
  ready(t2, 120_000)
  b = Sessions.new(user, [a], 10_000)
  for t <- [t1, t2], do: see(t, "Atlas Console · test")
  watch = Sessions.watch([a, b])

  # Four decisions a person decides: their gate gives each to the decider, the TUIs' user.
  titles =
    for n <- ~w(one two three four), into: %{} do
      {decision, _} =
        atlas_json(instance, [
          "put",
          "decision",
          "--title",
          "Choice #{n}",
          "--decision",
          "Choose #{n}.",
          "--category",
          "product"
        ])

      {decision["key"], "Choice #{n}"}
    end

  keys = Map.keys(titles)
  see(t1, "4 assigned to you", 30_000)

  step "Precision: an unrelated page gets no push; a page that depends on the write does", fn ->
    press(t2, "w")
    see(t2, "Agent requests")
    since = Sessions.now()
    {_, _} = atlas_json(instance, ["put", "agent", "--name", "Scout"])
    # The hint reached B before the command answered; B has handled it once it is quiet.
    :ok = Sessions.quiet(b, 5_000)
    assert Sessions.pushes(watch, b, since) == []

    start_page(t2)
    press(t2, "g")
    see(t2, "Scout")
    since = Sessions.now()
    {_, at} = atlas_json(instance, ["put", "agent", "--name", "Ranger"])
    by_hint(t2, "Ranger", at)
    :ok = Sessions.quiet(b, 5_000)

    pushes = Sessions.pushes(watch, b, since)
    assert pushes != []
    assert Enum.all?(pushes, &(&1["path"] == "/k/agent" and &1["reason"] == "hint"))
    assert "ranger" in Enum.map(Sessions.rows(List.last(pushes)), & &1.key)
  end

  step "Read-your-writes: the stored page shows Flow's outcome; `a` selects the row at its index",
       fn ->
         before = rows.(t1, keys)
         assert length(before) == 4
         [first, second | _] = before
         open_row(t1, titles[first.key])
         see(t1, "Decision #{first.key}: #{titles[first.key]}")
         press(t1, "a")
         see(t1, "Accept #{first.key}?")
         since = Sessions.now()
         at = press(t1, "y")

         # The first page after the key is the stored one, and it already shows what Flow
         # did with the answer: the decision handed on, one fewer assigned to you.
         stored(
           t1,
           ~r/3 assigned to you.*Decision #{first.key}: .*· stored at \d\d:\d\d:\d\d · position \d+/s,
           at
         )

         pages = Sessions.pages(watch, a, since)
         stored = Enum.find(pages, &(&1["reason"] == "stored"))
         assert stored["path"] == "/k/decision/#{first.key}"
         assert "coordinator" in Enum.map(Sessions.rows(stored), & &1.key)
         assert stored["count"] =~ ~r/^3 assigned to you/
         # Meanwhile the list it came from was flagged, without a read.
         assert Enum.any?(pages, fn page ->
                  page["path"] == "/" and page["reason"] == "pending" and
                    %{key: first.key, label: titles[first.key], pending: true} in Sessions.rows(
                      page
                    )
                end)

         refute Enum.any?(CoreLog.lines(), &(&1 =~ "settle timeout"))

         # Back on the list: the answered row left it; the row now at its index is selected.
         start_page(t1)
         gone(t1, "from cache")
         after_rows = rows.(t1, keys)
         # The other rows keep their order.
         assert Enum.map(after_rows, & &1.key) == Enum.map(before, & &1.key) -- [first.key]
         assert selected.(after_rows) == 0
         assert Enum.at(after_rows, 0).key == second.key
       end

  step "Marker: the answered row is pending until Flow settles; `f` selects the row at its index",
       fn ->
         before = rows.(t1, keys)
         assert length(before) == 3
         [_, middle, next] = before
         :ok = Sessions.quiet(a, 5_000)
         :ok = Sessions.quiet(b, 5_000)
         control = ControlTime.hold(self())
         flow = FlowTime.hold()

         try do
           open_row(t1, titles[middle.key])
           see(t1, "Decision #{middle.key}: #{titles[middle.key]}")
           press(t1, "f")
           see(t1, "Reject #{middle.key}")
           type(t1, "Not now: the page freshness proof.")
           since = Sessions.now()
           press(t1, "C-s")

           # Stored: the session asks Flow how far it settled and waits, at most its budget,
           # which is held.
           assert_receive {:held, ^a, {:settle_timeout, _}, 1_000}, 10_000
           position = Sessions.settling(a).position

           start_page(t1)
           pattern = ~r/› #{middle.key}\s+#{Regex.escape(titles[middle.key])}\s+⋯ being processed/
           screen = see(t1, pattern)
           assert length(Regex.scan(~r/being processed/, screen)) == 1
           assert selected.(rows.(t1, keys)) == 1

           # Every list page sent since the key shows the row, pending: none shows it gone.
           lists = for page <- Sessions.pages(watch, a, since), page["path"] == "/", do: page
           assert lists != []

           for page <- lists,
               do:
                 assert(
                   %{key: middle.key, label: titles[middle.key], pending: true} in Sessions.rows(
                     page
                   )
                 )

           # Flow catches up; the session hears it settled past the write.
           settling = Sessions.now()
           :ok = FlowTime.until(flow, fn -> Sessions.unmarked?(a) end, 10_000)
           gone(t1, "being processed")
           gone(t1, ~r/ #{middle.key}  /)
           assert :sys.get_state(a).settled >= position

           for page <- Sessions.pages(watch, a, settling), page["path"] == "/" do
             refute middle.key in Enum.map(Sessions.rows(page), & &1.key)
             refute Enum.any?(Sessions.rows(page), & &1.pending)
           end

           after_rows = rows.(t1, keys)
           assert Enum.map(after_rows, & &1.key) == Enum.map(before, & &1.key) -- [middle.key]
           assert selected.(after_rows) == 1
           assert Enum.at(after_rows, 1).key == next.key
         after
           FlowTime.release(flow)
           ControlTime.release(control)
         end
       end

  IO.puts("page freshness proof: #{Process.get(:e2e_steps)} steps passed")
after
  Tui.kill_server(socket)
end
