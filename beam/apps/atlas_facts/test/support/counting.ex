defmodule AtlasFacts.Counting do
  @moduledoc "The neutral model of the counting store's kinds (`AtlasFacts.CountingRela.schema/0`)."
  use AtlasFacts.TestModel, description: AtlasFacts.CountingRela.schema()
end
