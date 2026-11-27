# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

class DialyzerCheckTest < Minitest::Test
  def test_checks_each_project_and_reports_failures
    Dir.mktmpdir do |root|
      tool = File.join(root, 'platform/ops/dialyzer')
      bin = File.join(root, 'bin')
      FileUtils.mkdir_p([tool, bin, File.join(tool, '_build/dev/lib/dialyxir/ebin')])
      FileUtils.cp(File.join(__dir__, 'check.rb'), tool)
      %w[platform/atlas_bus products/software_factory platform/clients/tui].each do |project|
        FileUtils.mkdir_p(File.join(root, project))
        File.write(File.join(root, project, 'mix.exs'), '')
      end
      File.write(File.join(root, 'mix.exs'), '')
      File.write(File.join(bin, 'mix'), "#!/bin/sh\necho \"mix:$PWD:$*\" >> \"$CALLS\"\ncase \"$PWD:$1\" in */platform/clients/tui:run) exit 1;; esac\n")
      FileUtils.chmod(0o755, File.join(bin, 'mix'))
      system('git', 'init', '-q', root, exception: true)
      system('git', '-C', root, 'add', 'mix.exs', 'platform/atlas_bus/mix.exs', 'products/software_factory/mix.exs', 'platform/clients/tui/mix.exs', exception: true)
      calls = File.join(root, 'calls')
      env = { 'PATH' => "#{bin}:#{ENV.fetch('PATH')}", 'CALLS' => calls, 'MIX_ENV' => 'test' }
      output, status = Open3.capture2e(env, 'ruby', File.join(tool, 'check.rb'))
      refute status.success?
      assert_includes output, 'failed projects: platform/clients/tui'
      log = File.read(calls)
      assert_includes log, "mix:#{root}:run --no-start"
      assert_includes log, "mix:#{root}/products/software_factory:run --no-start"
      assert_includes log, "mix:#{root}/platform/clients/tui:run --no-start"
      refute_includes log, "mix:#{root}/platform/atlas_bus:run"
      assert_includes log, 'Code.prepend_paths(System.argv())'
      assert_includes log, '--force-check'
      assert_includes log, File.join(tool, '_build/dev/lib/dialyxir/ebin')
    end
  end
end
