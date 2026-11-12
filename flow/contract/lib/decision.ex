defmodule AtlasFlowContract.Decision do
  @moduledoc "The compatibility bridge observes status already authorized by Facts."
  use AtlasFlowGenerator.Schema

  subflow :decide, label: "Decide", subject: :decision do
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :debate
    start :create
    initial :proposed

    state :proposed, label: "Proposed" do
      present(
        expected: "Have it decided",
        why: "it is proposed",
        instructions:
          "Have it accepted or rejected, with decided_by and decided_at. A person accepts a product, security, one-way or principle decision; any other a person, or an agent under delegated_by. A principle names its enforced_by."
      )

      branch to: :accepted, when: "entity.status == 'accepted'"
      branch to: :rejected, when: "entity.status == 'rejected'"
    end

    final :accepted, label: "Accepted"
    final :rejected, label: "Rejected"
  end
end
