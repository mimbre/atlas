defmodule AtlasTui.Resize do
  @moduledoc """
  Tells the TUI when its terminal changes size (SIGWINCH), so it redraws at once: a page
  in parts goes side by side or one above the other as the terminal allows.
  """
  @behaviour :gen_event

  @doc "Send `:resized` to `pid` on every change of the terminal's size."
  def watch(pid) do
    with :ok <- :os.set_signal(:sigwinch, :handle),
         :ok <- :gen_event.add_handler(:erl_signal_server, __MODULE__, pid) do
      :ok
    end
  catch
    _, _ -> :error
  end

  @impl true
  def init(pid), do: {:ok, pid}

  @impl true
  def handle_event(:sigwinch, pid) do
    send(pid, :resized)
    {:ok, pid}
  end

  def handle_event(_signal, pid), do: {:ok, pid}

  @impl true
  def handle_call(_request, pid), do: {:ok, :ok, pid}
end
