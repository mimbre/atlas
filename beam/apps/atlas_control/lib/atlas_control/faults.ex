defmodule AtlasControl.Faults do
  @moduledoc """
  Failure actions, in the test environment only (IS-Atlas-23): what can be made to fail,
  so that each recovery can be seen in a client.

  On a browsing page (the start page, a list, a fact) Control offers `! Failures…`, a page
  of what can fail there. Control asks the layers over the Bus what they offer for the fact
  (class `fault`, which a prod Bus refuses), and adds what it causes itself:

  - Runtime: on a turn it runs, kill its agent; on an agent it runs through the stand-in,
    make it idle, silent, or end its turns empty, or put it back to work;
  - Flow: on a fact it runs a process for, kill that process;
  - Control: drop the next hint, take Control offline for 10 s, restart the node.

  Each opens a confirm that says what will be seen as it recovers; confirming causes it,
  and Control says what happened as a notice. A layer names the fact by key alone, and
  Control names no kind: what is offered is what the layers say.
  """

  alias AtlasBus.Envelope
  require AtlasControl.Blocks, as: Blocks

  @wait 1_000
  @run 5_000
  @offline 10_000

  @own [
    {"drop-hint", "Drop the next hint",
     "The Bus drops the hint of whatever is stored next. A client showing it sees the change " <>
       "at its next reconcile (within 5 s), not by hint."},
    {"offline", "Take Control offline for 10 s",
     "Control closes every client's connection and takes none for 10 s. Each client shows " <>
       "it is not connected, and comes back by itself."},
    {"restart", "Restart the node",
     "The node stops and starts again (atlas-ops restart). Clients lose Control and come back; " <>
       "Runtime ends the turns that ran and starts them again; Flow starts the process of " <>
       "every open fact again."}
  ]

  @doc "Whether failures are offered here: never in prod."
  def offered?, do: AtlasBus.environment() != "prod"

  @doc """
  What can fail on `on` (`nil` for the node, or `{kind, key}` for a fact):
  `[%{"fault", "label", "text", "by"}]`, the layers' first. From the calling process, which
  must be attached to the Bus.
  """
  def offers(on) do
    layers =
      case on do
        {_kind, key} ->
          (AtlasBus.endpoints()
           |> Enum.filter(
             &(String.starts_with?(&1, "runtime@") and not String.contains?(&1, "/"))
           )
           |> Enum.sort()
           |> Enum.flat_map(&ask(&1, key))) ++ ask("flow", key)

        nil ->
          []
      end

    own = for {fault, label, text} <- @own, do: offer(fault, label, text, "control")
    if offered?(), do: layers ++ own, else: []
  end

  defp offer(fault, label, text, by),
    do: %{"fault" => fault, "label" => label, "text" => text, "by" => by}

  defp ask(endpoint, key) do
    case call(endpoint, %{"do" => "offer", "key" => key}, @wait) do
      %{"offers" => offers} when is_list(offers) -> Enum.map(offers, &Map.put(&1, "by", endpoint))
      _ -> []
    end
  end

  # A fault message to a layer's endpoint, and its answer (nil without one in time).
  defp call(endpoint, content, wait) do
    envelope = %{Envelope.new("fault", "_fault") | address: endpoint}
    id = envelope.id

    case AtlasBus.send(envelope, content) do
      :ok ->
        receive do
          {:atlas_bus, %Envelope{id: ^id, class: "answer"}, answer} -> answer
        after
          wait -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc "Cause `fault` on `on`: `{:ok, what happened}` or `{:error, why}`."
  def run(fault, on) do
    case Enum.find(offers(on), &(&1["fault"] == fault)) do
      nil ->
        {:error, "#{label_of(on)} offers no failure #{inspect(fault)} (any more)."}

      %{"by" => "control"} ->
        own(fault)

      %{"by" => endpoint} ->
        {_kind, key} = on

        case call(endpoint, %{"do" => "run", "fault" => fault, "key" => key}, @run) do
          %{"done" => done} -> {:ok, done}
          %{"refused" => why} -> {:error, why}
          nil -> {:error, "#{endpoint} did not answer."}
        end
    end
  end

  defp own("drop-hint") do
    :ok = AtlasBus.drop_hints(1)
    {:ok, "The Bus drops the next hint: the next change shows at a reconcile, not by hint."}
  end

  # Later, so the client is told first; the session that asks is closed too.
  defp own("offline") do
    spawn(fn ->
      Process.sleep(200)
      AtlasControl.Gateway.offline(@offline)
    end)

    {:ok, "Control goes offline for #{div(@offline, 1000)} s."}
  end

  defp own("restart") do
    case System.get_env("ATLAS_ROOT") do
      root when is_binary(root) and root != "" ->
        ops = Path.join(root, "bin/atlas-ops")

        spawn(fn ->
          Process.sleep(200)

          System.cmd("/bin/sh", [
            "-c",
            ~s(nohup "$0" restart --env "$1" > /dev/null 2>&1 &),
            ops,
            AtlasBus.environment()
          ])
        end)

        {:ok, "The node restarts (atlas-ops restart)."}

      _ ->
        {:error,
         "This node does not know its atlas-ops (no ATLAS_ROOT): it cannot restart itself."}
    end
  end

  @doc "The page of `route`: the failures on it, or the confirm for one."
  def page({:faults, on}, offers) do
    rows =
      for offer <- offers,
          do:
            Blocks.row(
              label: offer["label"],
              detail: by(offer["by"]),
              to: AtlasControl.Pages.path({:fault, offer["fault"], on})
            )

    list =
      Blocks.list(
        title: "What can fail #{if on, do: "on #{elem(on, 1)}", else: "on this node"}",
        rows: rows,
        empty: "Nothing can be made to fail here.",
        actions: []
      )

    view("Failures: #{label_of(on)}", back(on), [{"list", list}])
  end

  def page({:fault, fault, on}, offers) do
    faults = AtlasControl.Pages.path({:faults, on})

    confirm =
      case Enum.find(offers, &(&1["fault"] == fault)) do
        nil ->
          Blocks.confirm(
            title: "Not offered",
            text: "#{label_of(on)} offers no failure #{inspect(fault)} (any more).",
            cancel_to: faults
          )

        offer ->
          Blocks.confirm(
            title: "#{offer["label"]}?",
            text: offer["text"],
            confirm_label: offer["label"],
            confirm_to: AtlasControl.Pages.call_to({:fault, fault, on}),
            cancel_to: faults
          )
      end

    view(Map.get(Enum.find(offers, %{}, &(&1["fault"] == fault)), "label", "Failure"), faults, [
      {"confirm", confirm}
    ])
  end

  @doc "The page a failure on `on` returns to: the fact's, or the start page."
  def after_run({kind, key}), do: {:item, kind, key}
  def after_run(nil), do: :home

  @doc """
  A browsing page with `! Failures…` added (test only): on its last list or item block, so
  it comes after all of the page's own actions.
  """
  def with_action(page, route) do
    to =
      case route do
        {:item, kind, key} ->
          AtlasControl.Pages.path({:faults, {kind, key}})

        route when route == :home or elem(route, 0) == :list ->
          AtlasControl.Pages.path({:faults, nil})

        _ ->
          nil
      end

    if offered?() and to do
      action = Blocks.action(label: "Failures…", key: "!", to: to)

      {blocks, _} =
        page.blocks
        |> Enum.reverse()
        |> Enum.map_reduce(false, fn
          %{"type" => type, "props" => props} = block, false when type in ["list", "item"] ->
            actions = (props["actions"] || []) ++ [action]
            {%{block | "props" => Map.put(props, "actions", actions)}, true}

          block, done ->
            {block, done}
        end)

      %{page | blocks: Enum.reverse(blocks)}
    else
      page
    end
  end

  defp view(title, back, content),
    do: Map.merge(%{title: title, back: back}, Blocks.view_model(content, []))

  defp back({kind, key}), do: AtlasControl.Pages.path({:item, kind, key})
  defp back(nil), do: "/"

  defp label_of({_kind, key}), do: key
  defp label_of(nil), do: "this node"

  defp by("runtime@" <> machine), do: "Runtime on #{machine}"
  defp by("flow"), do: "Flow"
  defp by(_), do: "Control"
end
