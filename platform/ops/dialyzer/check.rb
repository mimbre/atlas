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

  # Compile without loading runtime.exs, then restore the paths Mix prunes.
  # Shared lockfiles do not make these independent projects umbrella children.
  invoke = <<~ELIXIR
    Mix.start()
    paths = :code.get_path()
    Code.compile_file("mix.exs")
    Mix.Task.run("loadconfig")
    Mix.Task.run("compile")
    :code.add_paths(paths)
    Code.prepend_paths(System.argv())
    config = Keyword.put(Mix.Project.config()[:dialyzer] || [], :no_umbrella, true)
    Mix.ProjectStack.merge_config(dialyzer: config)
    Mix.Task.run("dialyzer", ["--force-check"])
  ELIXIR

  failed = []
  projects.each do |project|
    abort "dialyzer: dependency setup failed for #{project}" unless run('mix', 'deps.get', '--check-locked', dir: project)
    next if run('elixir', '-e', invoke, '--', *paths, dir: project)

    # Dialyxir uses status 2 for findings and 1 for errors.
    abort "dialyzer: could not analyze #{project}" unless $?&.exitstatus == 2
    failed << project
  end
  abort "dialyzer: failed projects: #{failed.join(', ')}" unless failed.empty?
end
