# The tests read the files the contract generates: write them first.
Mix.Task.run("runtime_backend.gen")
ExUnit.start()
