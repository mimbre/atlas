defmodule AtlasBus do
  @moduledoc """
  The Bus: every layer talks only to it.

  It reads a message's envelope (`AtlasBus.Envelope`) and never its content. It routes on
  the envelope's class:

  | Class      | From      | Goes to                                                     |
  |------------|-----------|-------------------------------------------------------------|
  | `fact`     | any layer | the store (Facts), to be stored                             |
  | `read`     | any layer | the store (Facts), to be answered; or answered where it is  |
  |            |           | sent, by the store's reader (`answer_reads/1`)              |
  | `request`  | any layer | its address only, without storage or hints                 |
  | `stored`   | the store | its address, the sender of the fact (acknowledgement), and  |
  |            |           | every listener of its kind (hint): one message, both jobs   |
  | `refused`  | the store | its address only                                            |
  | `answer`   | the store | its address only                                            |
  |            | or a layer|                                                             |
  | `fault`    | Control   | its address only (a layer's endpoint): a failure to offer   |
  |            |           | or cause, in the test environment only; a prod Bus refuses  |
  |            |           | it (IS-Atlas-23)                                            |

  A reply carries the id of the message it answers. Delivery is not promised: a sender
  that gets no reply sends the same message again, with the same id.

  A process receives messages as `{:atlas_bus, %AtlasBus.Envelope{}, content}`.
  """

  alias AtlasBus.{Envelope, Router}

  @doc "Make the calling process the endpoint `name`; replies addressed to `name` come here."
  def attach(name) do
    if AtlasBus.Link.client?() do
      machine = AtlasBus.Link.settings()["machine"]

      if AtlasBus.Link.allowed?(name, machine) do
        with :ok <- Router.attach(name), do: AtlasBus.Link.Client.sync(self())
      else
        {:error, :endpoint_not_allowed}
      end
    else
      Router.attach(name)
    end
  end

  @doc "Send the calling process every hint (a `stored`) of kind `kind`."
  def listen(kind) do
    with :ok <- Router.listen(kind) do
      if AtlasBus.Link.client?(), do: AtlasBus.Link.Client.sync(self()), else: :ok
    end
  end

  @doc """
  Let reads be answered where they are sent, so they do not wait behind the store's other
  work: called by the store's endpoint, with `{module, arg}`. A read is then answered in
  the sending process by `module.answer(arg, envelope, content)`, which returns
  `{:answer, content}` (sent back as the store's `answer`) or `:pass` (the read goes to the
  store, as without a reader). A read waits for the store as before while a fact its sender
  sent is not answered yet, so a sender always reads after its own facts. The reader goes
  with the endpoint. `{:error, :not_the_store}` when the caller is not the store.
  """
  defdelegate answer_reads(reader), to: Router

  @doc "The attached endpoint names (envelopes only, no layer knowledge)."
  def endpoints do
    Registry.select(AtlasBus.Endpoints, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  How many messages wait at the endpoint `name`, unread (its process's queue), or nil when
  no endpoint is attached as `name` on this node. Envelopes only: it never reads them, and
  it does not wait for the endpoint, so it answers while the endpoint is busy or stuck
  (Control's health page, the length of Facts' queue: IS-Atlas-117).
  """
  def waiting(name) when is_binary(name) do
    with [{pid, _}] <- Registry.lookup(AtlasBus.Endpoints, name),
         {:message_queue_len, n} <- Process.info(pid, :message_queue_len) do
      n
    else
      _ -> nil
    end
  end

  @doc """
  Put a message on the Bus from the calling process, which must be attached.
  Returns an error only for a message the Bus will not route.
  """
  def send(%Envelope{} = envelope, content), do: Router.route(envelope, content)
  def send(_other, _content), do: {:error, :not_an_envelope}

  @doc "The endpoint facts and reads go to."
  def store, do: Application.fetch_env!(:atlas_bus, :store)

  @doc "The environment this Bus serves."
  def environment, do: Application.fetch_env!(:atlas_bus, :environment)

  @doc "Test environment only (prod refuses): drop the next `count` hints, to show reconciling."
  defdelegate drop_hints(count), to: Router

  @doc "The classes of message the Bus routes."
  def classes, do: Router.classes()
end
