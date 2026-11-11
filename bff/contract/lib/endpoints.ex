defmodule AtlasBFFContract.Endpoints do
  @moduledoc "Control form, session and agent endpoint declarations."

  defmacro __using__(_opts) do
    quote do
      # The form submits Control takes: {"op": "submit", "endpoint": name, "params": {...},
      # "values": {name => text}}, as a form's submit_to or a confirm's confirm_to names them
      # (a `call`); the path is what the endpoint is at. The values are the form's inputs by
      # name; what they hold comes from rela's description, at run time, so no kind is named
      # here. stored: the page to go to next (reason "stored"); refused: the form again, with
      # its errors (reason "refused"). Notices come with either.
      @submit [
        wire: :submit,
        call: :submit,
        takes: :values,
        replies: [stored: :view_model, refused: :view_model]
      ]

      defendpoint :create, "/k/:kind/new", @submit

      defendpoint :queue_worker_guidance,
                  "/workers/:machine/:worker/:turn/:attempt/guidance",
                  @submit

      defendpoint :create_under, "/k/:kind/new/:relation/:parent", @submit
      defendpoint :update, "/k/:kind/:key/edit", @submit
      defendpoint :delete, "/k/:kind/:key/delete", @submit
      defendpoint :link, "/k/:kind/:key/links/:relation", @submit
      defendpoint :accept, "/k/:kind/:key/set/:relation", @submit
      defendpoint :reopen, "/k/:kind/:key/remove/:relation", @submit
      defendpoint :fault, "/fault/:fault", @submit
      defendpoint :fact_fault, "/k/:kind/:key/fault/:fault", @submit

      # The session's other messages, in JSON lines over the socket (bff/README.md, Protocol).
      # Each endpoint's call is the message's "op".
      defendpoint :boot,
        wire: :boot,
        call: :boot,
        takes: :boot_request,
        replies: [shell: :shell, error: :boot_error]

      defendpoint :turn,
        wire: :turn,
        call: :turn,
        replies: [turn: :turn_context, error: :turn_context]

      defendpoint :turn_end,
        call: :turn_end,
        takes: :turn_outcome,
        wire: :turn_end,
        replies: [stored: :view_model, error: :turn_context, refused: :view_model]

      defendpoint :hello,
        wire: :hello,
        call: :hello,
        takes: :hello,
        replies: [welcome: :welcome, page: :view_model, bye: :bye]

      # Read the page shown again, from Facts: what a client does on an interval.
      defendpoint :refresh, wire: :refresh, call: :refresh, replies: [page: :view_model]

      # What Control sends unasked: a page again when a change it shows was stored by anyone
      # (reason "hint"), a notice, or bye before it closes.
      defendpoint :hint, wire: :hint, call: :page, replies: [page: :view_model]
      defendpoint :notice, wire: :notice, call: :notice, replies: [notice: :notice]
      defendpoint :bye, wire: :bye, call: :bye, replies: [bye: :bye]

      defendpoint :ask,
        wire: :ask,
        call: :ask,
        takes: :ask,
        replies: [plan: :plan, notice: :notice]

      defendpoint :run,
        wire: :run,
        call: :run,
        takes: :run,
        replies: [plan: :plan, notice: :notice]

      defendpoint :cancel, wire: :cancel, call: :cancel, replies: [plan: :plan]
      defendpoint :stop, wire: :stop, call: :stop, replies: [plan: :plan, notice: :notice]
    end
  end
end
