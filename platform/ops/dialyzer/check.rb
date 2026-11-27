# frozen_string_literal: true

require 'open3'

ENV['MIX_ENV'] = 'dev'
$stdout.sync = true

root = File.expand_path('../../..', __dir__)
tool = __dir__
Dir.chdir(root) do
  files, status = Open3.capture2('git', 'ls-files', '-z', '--', 'mix.exs', '**/mix.exs')
  abort 'dialyzer: cannot list Mix projects' unless status.success?

  projects = files.split("\0").map { |file| File.dirname(file) }
  # These apps are analyzed together through the software factory umbrella.
  umbrella_apps = %w[atlas_bus atlas_code atlas_control atlas_facts atlas_flow atlas_gates atlas_learn atlas_runtime]
  projects.reject! { |path| umbrella_apps.any? { |app| path == "platform/#{app}" } || path == 'platform/ops/dialyzer' }
  abort 'dialyzer: no Mix projects found' if projects.empty?

  def run(*command, dir:)
    puts "+ (cd #{dir} && #{command.join(' ')})"
    system(*command, chdir: dir)
  end

  abort 'dialyzer: tool dependencies failed' unless run('mix', 'deps.get', '--check-locked', dir: tool) &&
                                                   run('mix', 'compile', dir: tool)
  paths = Dir.glob(File.join(tool, '_build', 'dev', 'lib', '*', 'ebin'))
  abort 'dialyzer: tool build has no BEAM paths' if paths.empty?

  # Mix prunes paths during compilation, so load the tool after the project compiles.
  # Shared lockfiles do not make these independent projects umbrella children.
  invoke = <<~ELIXIR
    Code.prepend_paths(System.argv())
    config = Keyword.put(Mix.Project.config()[:dialyzer] || [], :no_umbrella, true)
    Mix.ProjectStack.merge_config(dialyzer: config)
    Mix.Task.run("dialyzer", ["--force-check"])
  ELIXIR

  failed = projects.reject do |project|
    run('mix', 'deps.get', '--check-locked', dir: project) &&
      run('mix', 'run', '--no-start', '-e', invoke, '--', *paths, dir: project)
  end
  abort "dialyzer: failed projects: #{failed.join(', ')}" unless failed.empty?
end
