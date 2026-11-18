defmodule AtlasFlow.Supervision do
  @moduledoc """
  Who supervises a subject's work (decision 2026-11-17 §5.6; plan m3 §3.1): for a subject,
  the nearest run with a declared supervised span, found by walking the model's parent
  relations upwards (as the Engine's hint discovery does, at most 8 levels).

  - `{:supervised, holder, run_key}`: that run is active, its state lies in one of its
    subflow's spans, and it has a human supervisor (`holder`, the supervisor's key);
  - `:unsupervised`: that run has no supervisor, its state lies outside every span, it is
    not active, or no run with a span is found;
  - `:unavailable`: Facts did not say.

  `runner` is what `AtlasFlow.Model.load/3` gives (`config`, `relations`). Every read goes
  from the calling process, which must be attached to the Bus. Flow names no kind here:
  the kinds come from the model.
  """

  alias AtlasFlow.Runs.Store
  alias AtlasFlow.Talk

  @depth 8

  @type answer :: {:supervised, String.t(), String.t()} | :unsupervised | :unavailable

  @doc "The supervision of the subject `{kind, key}` (see the moduledoc)."
  @spec of(map(), String.t(), String.t()) :: answer()
  def of(%{config: config} = runner, kind, key) when is_map(config) do
    case config["supervision"] do
      %{} -> walk(runner, kind, key, @depth)
      _ -> :unsupervised
    end
  end

  def of(_runner, _kind, _key), do: :unsupervised

  defp walk(_runner, _kind, _key, 0), do: :unsupervised

  defp walk(runner, kind, key, depth) do
    case own(runner, kind, key) do
      {:found, answer} -> answer
      :none -> up(runner, kind, key, depth)
      :unavailable -> :unavailable
    end
  end

  # The latest run with a span on this subject, if any.
  defp own(%{config: config}, kind, key) do
    spans = config["supervision"]["spans"] || %{}

    flows =
      for {name, selection} <- Enum.sort(config["selection"] || %{}),
          selection["subject"] == kind,
          (spans[name] || []) != [],
          do: name

    Enum.reduce_while(flows, :none, fn name, :none ->
      case Store.latest(config, name, kind, key) do
        {:ok, nil} -> {:cont, :none}
        {:ok, run} -> {:halt, {:found, answer(run, spans[name])}}
        {:error, _} -> {:halt, :unavailable}
      end
    end)
  end

  defp answer(run, spans) do
    in_span? = Enum.any?(spans, &(run["state"] in (&1["states"] || [])))
    holder = run["supervised_by"]

    if run["status"] == "active" and in_span? and is_binary(holder) and holder != "",
      do: {:supervised, holder, run["key"]},
      else: :unsupervised
  end

  # The subject's parents, through the relations the model marks `parent`, nearest first.
  defp up(%{relations: relations} = runner, kind, key, depth) do
    case Talk.read(kind, %{"key" => key, "plain" => true}) do
      %{"fact" => %{} = fact} ->
        links = fact["links"] || %{}

        parents =
          for {relation, %{"parent" => true, "from" => from, "to" => [to]}} <-
                Enum.sort(relations || %{}),
              kind in from,
              parent <- List.wrap(links[relation]),
              is_binary(parent),
              do: {to, parent}

        Enum.reduce_while(parents, :unsupervised, fn {k, p}, acc ->
          case walk(runner, k, p, depth - 1) do
            :unsupervised -> {:cont, acc}
            answer -> {:halt, answer}
          end
        end)

      %{"fact" => nil} ->
        :unsupervised

      _ ->
        :unavailable
    end
  end
end
