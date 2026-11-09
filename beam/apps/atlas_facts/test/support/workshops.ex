defmodule AtlasFacts.Workshops do
  @moduledoc """
  The neutral workshop with one more rule each, for the tests of what Facts does by a
  model's rules (`AtlasFacts.TestModel`).
  """
  alias AtlasFacts.Workshop.Description

  defmodule Asked do
    @moduledoc "A create asks only a title: an addition rela does not serve."
    use AtlasFacts.TestModel,
      description:
        Description.with(%{
          "_about" => "x",
          "entities" => %{"widget" => %{"create" => %{"ask" => ["title"]}}}
        })
  end

  defmodule Tagged do
    @moduledoc "A widget has a tag, made and deleted with it (a component)."
    use AtlasFacts.TestModel,
      description:
        Description.with(%{
          "entities" => %{
            "tag" => %{"plural" => "tags", "properties" => %{"title" => %{"type" => "string"}}}
          },
          "relations" => %{
            "tagged" => %{
              "from" => ["widget"],
              "to" => ["tag"],
              "max_outgoing" => 1,
              "component" => %{"key" => "T-{key}", "values" => %{"title" => "{key}"}}
            }
          }
        })
  end

  defmodule Phased do
    @moduledoc "How far a widget is, from the phase of its parts."
    use AtlasFacts.TestModel,
      description:
        Description.with(%{
          "progress" => %{"order" => ["rough", "fine"]},
          "entities" => %{
            "part" => %{"properties" => %{"phase" => %{"type" => "string"}}},
            "widget" => %{
              "progress" => %{"over" => "of_widget", "field" => "phase", "own" => "shade"}
            }
          }
        })
  end

  defmodule Owned do
    @moduledoc "A widget is owned by a maker or a part."
    use AtlasFacts.TestModel,
      description:
        Description.with(%{
          "relations" => %{
            "owned_by" => %{"from" => ["widget"], "to" => ["maker", "part"], "max_outgoing" => 1}
          }
        })
  end

  defmodule Lit do
    @moduledoc """
    A dark or lit widget is never edited except to be lit, and a dark widget that replaces
    others lights them in the same write.
    """
    use AtlasFacts.TestModel,
      description:
        Description.with(%{
          "relations" => %{"replaces" => %{"from" => ["widget"], "to" => ["widget"]}},
          "entities" => %{
            "widget" => %{
              "frozen" => %{
                "when" => %{"shade" => ["dark", "light"]},
                "only" => %{"shade" => ["light"]},
                "error" => "{key} is {value}"
              },
              "replaces" => %{
                "relation" => "replaces",
                "when" => %{"shade" => ["dark"]},
                "of" => %{"shade" => ["dark", "light"]},
                "set" => %{"shade" => "light"},
                "error" => "{key} is not dark"
              }
            }
          }
        })
  end

  defmodule Delegated do
    @moduledoc "A maker rules a widget dark, or a part under a maker's delegation."
    use AtlasFacts.TestModel,
      description:
        Description.with(%{
          "relations" => %{
            "under" => %{
              "from" => ["widget"],
              "to" => ["maker"],
              "max_outgoing" => 1,
              "only_target" => %{
                "error" => "only the delegator sets under, to themselves",
                "also" => ["importer"]
              }
            },
            "ruled_by" => %{"from" => ["widget"], "to" => ["maker", "part"], "max_outgoing" => 1}
          },
          "entities" => %{
            "widget" => %{
              "authority" => %{
                "when" => %{"shade" => ["dark"]},
                "by" => "ruled_by",
                "kind" => "maker",
                "only_kind_when" => [%{"done" => [true]}],
                "delegated_by" => "under",
                "writes" => %{"shade" => ["dark"]},
                "error" => "needs authority",
                "writer_error" => "only its ruler decides"
              }
            }
          }
        })
  end

  defmodule Made do
    @moduledoc "Only a maker makes a widget dark, as the one it is made by."
    use AtlasFacts.TestModel,
      description:
        Description.with(%{
          "entities" => %{
            "widget" => %{
              "authority" => %{
                "when" => %{"shade" => ["dark"]},
                "by" => "made_by",
                "kind" => "maker",
                "writes" => %{"shade" => ["dark"]},
                "error" => "needs its maker",
                "writer_error" => "only its maker makes it dark"
              }
            }
          }
        })
  end
end

defmodule AtlasFacts.Workshops.Accepted do
  @moduledoc """
  Parts go under a widget (a parent relation) and a maker accepts the widget: at most one
  rough part per widget, a widget is accepted only once every part under it is made, an
  accepted widget takes no new part, and only a connector or a migration stamps one.
  """
  use AtlasFacts.TestModel,
    description:
      AtlasFacts.Workshop.Description.with(%{
        "types" => %{
          "phase" => %{"values" => ["rough", "fine"], "labels" => %{"rough" => "Rough"}}
        },
        "entities" => %{
          "widget" => %{"label" => "Widget"},
          "part" => %{
            "label" => "Part",
            "properties" => %{"phase" => %{"type" => "phase"}},
            "completion" => %{"by" => "made_by"}
          }
        },
        "relations" => %{
          "of_widget" => %{
            "parent" => true,
            "limit" => %{
              "max" => 1,
              "field" => "phase",
              "values" => ["rough"],
              "error" => "{parent} already has {child} ({value})"
            }
          },
          "accepted_by" => %{
            "from" => ["widget"],
            "to" => ["maker"],
            "max_outgoing" => 1,
            "closes_parent" =>
              "{parent} is accepted; reopen it first, or put this under another {kind}",
            "requires_completed_children" => "{key} has {children} open"
          },
          "stamped_by" => %{
            "from" => ["widget"],
            "to" => ["maker"],
            "max_outgoing" => 1,
            "set_by" => ["connector", "migration"]
          }
        }
      })
end
