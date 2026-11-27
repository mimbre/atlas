# frozen_string_literal: true

require 'open3'

ENV['MIX_ENV'] = 'dev'
$stdout.sync = true

root = File.expand_path('../../..', __dir__)
tool = __dir__
Dir.chdir(root) do
  files, status = Open3.capture2('git', 'ls-files', '-z', '--', '**/mix.exs')
  abort 'dialyzer: cannot list Mix projects' unless status.success?

  projects = files.split("\0").map { |file| File.dirname(file) }
  # The umbrella checks these apps together; running their Mix projects alone is not equivalent.
  projects.reject! { |path| path.match?(%r{\Aplatform/atlas_[^/]+\z}) || path == 'platform/ops/dialyzer' }
  abort 'dialyzer: no Mix projects found' if projects.empty?

  def run(*command, dir:)
    puts "+ (cd #{dir} && #{command.join(' ')})"
    system(*command, chdir: dir)
  end

  abort 'dialyzer: tool dependencies failed' unless run('mix', 'deps.get', '--check-locked', dir: tool) &&
                                                   run('mix', 'compile', dir: tool)
  paths = Dir.glob(File.join(tool, '_build', 'dev', 'lib', '*', 'ebin')).flat_map { |path| ['-pa', path] }
  abort 'dialyzer: tool build has no BEAM paths' if paths.empty?

  failed = projects.reject do |project|
    run('mix', 'deps.get', '--check-locked', dir: project) &&
      run('elixir', *paths, '-S', 'mix', 'dialyzer', '--force-check', dir: project)
  end
  abort "dialyzer: failed projects: #{failed.join(', ')}" unless failed.empty?
end
