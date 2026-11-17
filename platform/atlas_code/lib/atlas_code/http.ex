defmodule AtlasCode.Http do
  @moduledoc """
  inets `customize` hook for Code's HTTP API: request bodies must have a `Content-Length`.

  inets streams only `Content-Length` bodies to `AtlasCode.do/1` in `max_client_body_chunk`
  pieces. It buffers a `chunked` body whole, up to `max_body_size`, before `do/1` runs, so
  neither the token nor the per-endpoint limit would be checked first. Any `transfer-encoding`
  header is therefore given a value inets does not know. inets then answers 501 and closes the
  connection without reading the body. Dropping the header instead would make inets read the
  body as the next request.
  """
  @behaviour :httpd_custom_api

  # inets lowercases header names before this hook runs.
  @impl true
  def request_header({~c"transfer-encoding", _encoding}),
    do: {true, {~c"transfer-encoding", ~c"refused"}}

  def request_header(header), do: {true, header}
end
