defmodule AtlasTui.Browser do
  @moduledoc """
  Opens a web address in the default browser: `open` on macOS, `xdg-open` elsewhere. An
  environment's settings may name another command (`"browser"`), such as a stand-in that
  only records the address, so a test opens nothing. The command gets the address as its
  one argument, never through a shell, and runs apart from the TUI, so a slow browser
  never holds up the screen. Only http and https addresses are opened.
  """

  alias AtlasTui.Model

  def open(url, settings) do
    if Model.openable?(url) do
      command = command(settings)

      spawn(fn ->
        case System.find_executable(command) do
          nil -> :ok
          path -> System.cmd(path, [url], stderr_to_stdout: true)
        end
      end)

      :ok
    else
      {:error, :not_http}
    end
  end

  @doc "The command that opens an address, from the settings or the system."
  def command(settings) do
    case settings["browser"] do
      command when is_binary(command) and command != "" -> Path.expand(command)
      _ -> if match?({:unix, :darwin}, :os.type()), do: "open", else: "xdg-open"
    end
  end
end
