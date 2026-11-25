# The tests read the files the contract generates: write them first.
Mix.Task.run("runtime_boundary.gen")
ExUnit.start()
