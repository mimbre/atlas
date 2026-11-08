defmodule AtlasRuntime.CodeStub do
  @moduledoc "Loopback stand-in for the Code service: answers every request with one fixed JSON reply."
  require Record
  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  @doc "Starts the stub; each request is also sent to the caller as `{:code_request, headers, body}`."
  def start(status, reply) do
    root = String.to_charlist(System.tmp_dir!())

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"code-stub",
        server_root: root,
        document_root: root,
        modules: [__MODULE__],
        code_stub: {status, reply, self()}
      )

    {pid, :httpd.info(pid)[:port]}
  end

  @doc false
  def unquote(:do)(request) do
    {status, reply, owner} = :httpd_util.lookup(mod(request, :config_db), :code_stub)
    send(owner, {:code_request, mod(request, :parsed_header), :erlang.list_to_binary(mod(request, :entity_body))})
    json = JSON.encode!(reply)
    headers = [code: status, content_type: ~c"application/json", content_length: Integer.to_charlist(byte_size(json))]
    {:proceed, [response: {:response, headers, [json]}]}
  end
end
