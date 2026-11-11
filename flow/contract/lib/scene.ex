defmodule AtlasFlowContract.Scene do
  @moduledoc """
  The scene subflow: a scene is broken down into use cases (`children`), built until
  none is open (`open_children`), then tested and accepted by an acceptor.
  `children` and `open_children` are the composition's count of the use cases in
  the scene. A rejection goes to a rework pass; a new open use case sends it back to
  building, and a rework that ends either way returns to the acceptor.
  """
  use AtlasFlowGenerator.Schema

  subflow :test_and_accept_scene, label: "Build, test and accept", subject: :scene do
    run_as "system:sf-flow"
    owner via: :assignment, relation: :assigned_to
    start :create
    initial :break_down

    state :break_down, label: "Break it down into use cases" do
      pass :architect, mode: :author, writes: :none
      branch to: :building, by: :atlas, when: "entity.children > 0"
    end

    state :building, label: "Build it" do
      branch to: :break_down, by: :atlas, when: "entity.children == 0"
      branch to: :to_test, by: :atlas, when: "entity.open_children == 0"
    end

    state :to_test, label: "Test it" do
      wait_for [:acceptor], on: :verdict, accept: :accepted, reject: :rework
    end

    state :rework, label: "Rework it" do
      branch to: :building, by: :atlas, when: "entity.open_children > 0"

      pass :architect,
        mode: :rework,
        input: {:channel, :newest_since_last_pass},
        on: [delivered: :to_test, failed: {:to_test, "Rework failed; the acceptor decides"}]
    end

    final :accepted, label: "Accepted"
  end
end
