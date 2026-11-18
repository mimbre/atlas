# frozen_string_literal: true

# The test of bin/lib/test_waits.rb, on purpose-made trees under a temp folder:
#   ruby bin/lib/test_waits_test.rb
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative 'test_waits'

class TestWaitsTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('test-waits')
    write('platform/app/mix.exs', "defmodule App.MixProject do\nend\n")
    write('platform/app/test/test_helper.exs', "ExUnit.start()\n")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def write(relative, text)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def hits(text, path: 'platform/app/test/a_test.exs')
    write(path, text)
    _errors, hits = TestWaits.check(@root, '')
    hits.map { |h| [h.rule, h.line] }
  end

  def errors(allow)
    TestWaits.check(@root, allow).first
  end

  def test_sleeps_count_but_infinity_and_comments_do_not
    assert_equal [['sleep', 1], ['sleep', 2]],
                 hits("Process.sleep(10)\n:timer.sleep(@wait)\nProcess.sleep(:infinity)\n# Process.sleep(5)\n")
  end

  def test_a_string_interpolation_is_no_comment
    assert_equal [['sleep', 1]], hits("x = \"\#{a}\"; Process.sleep(1)\n")
  end

  def test_receive_timeouts_below_the_threshold
    source = <<~EX
      @short 50
      @long 5_000
      assert_receive {:a, _}, 999
      assert_receive {:a, _}, 1_000
      refute_receive :b, @short
      refute_receive :b, @long
      assert_receive(
        {:c, %{x: 1, y: [2, 3]}},
        200
      )
      refute_receive :d
      assert_received :e
      refute_received :f
    EX
    assert_equal [['receive_timeout', 3], ['receive_timeout', 5], ['receive_timeout', 7],
                  ['receive_timeout', 11]], hits(source)
  end

  def test_a_bare_assert_receive_is_short_unless_the_project_raises_the_default
    assert_equal [['receive_timeout', 1]], hits("assert_receive :a\n")
    write('platform/app/test/test_helper.exs', "ExUnit.start(AtlasTestAwait.exunit_options())\n")
    assert_equal [], hits("assert_receive :a\n")
    write('platform/app/test/test_helper.exs', "ExUnit.start(assert_receive_timeout: 30_000)\n")
    assert_equal [], hits("assert_receive :a\n")
    write('platform/app/test/test_helper.exs', "ExUnit.start(assert_receive_timeout: 500)\n")
    assert_equal [['receive_timeout', 1]], hits("assert_receive :a\n")
  end

  def test_a_raised_default_never_covers_a_bare_refute
    write('platform/app/test/test_helper.exs', "ExUnit.start(AtlasTestAwait.exunit_options())\n")
    assert_equal [['receive_timeout', 1]], hits("refute_receive :a\n")
  end

  def test_an_unknown_timeout_expression_counts
    assert_equal [['receive_timeout', 1]], hits("assert_receive :a, timeout\n")
  end

  def test_short_after_clauses_but_not_a_flush
    source = "receive do\n  :x -> 1\nafter\n  50 -> 2\nend\nreceive do\nafter\n  0 -> :ok\nend\nreceive do\nafter\n  1_000 -> :ok\nend\n"
    # Reported at its `after`.
    assert_equal [['after_timeout', 3]], hits(source)
  end

  def test_only_test_files_under_platform_and_products
    write('platform/app/lib/a.ex', "Process.sleep(10)\n")
    write('platform/app/deps/x/test/x_test.exs', "Process.sleep(10)\n")
    write('platform/app/_build/test/y_test.exs', "Process.sleep(10)\n")
    write('elsewhere/test/z_test.exs', "Process.sleep(10)\n")
    write('products/p/test/support/s.ex', "Process.sleep(10)\n")
    write('products/p/e2e/b_test.exs', "Process.sleep(10)\n")
    _errors, found = TestWaits.check(@root, '')
    assert_equal ['products/p/e2e/b_test.exs', 'products/p/test/support/s.ex'], found.map(&:path).sort
  end

  def test_a_hit_outside_the_allowlist_fails
    write('platform/app/test/a_test.exs', "Process.sleep(10)\n")
    assert_equal ['platform/app/test/a_test.exs:1: sleep: Process.sleep(10'], errors('')
  end

  def test_the_allowlist_count_is_exact
    write('platform/app/test/a_test.exs', "Process.sleep(10)\nProcess.sleep(20)\n")
    assert_equal [], errors("platform/app/test/a_test.exs sleep 2 kept: why\n")
    more = errors("platform/app/test/a_test.exs sleep 1 kept: why\n")
    assert_equal 3, more.size
    assert(more.all? { |e| e.start_with?('platform/app/test/a_test.exs') })
    assert_equal 1, errors("platform/app/test/a_test.exs sleep 3 kept: why\n").size
  end

  def test_a_line_without_a_hit_or_a_file_is_stale
    write('platform/app/test/a_test.exs', "assert true\n")
    assert_equal 1, errors("platform/app/test/a_test.exs sleep 1 kept: why\n").size
    assert_equal 1, errors("platform/app/test/gone_test.exs sleep 1 kept: why\n").size
  end

  def test_a_line_needs_a_known_rule_a_count_and_a_reason
    write('platform/app/test/a_test.exs', "assert true\n")
    ['platform/app/test/a_test.exs sleep 1', 'platform/app/test/a_test.exs nap 1 why',
     'platform/app/test/a_test.exs sleep x why'].each do |line|
      assert(errors("#{line}\n").any? { |e| e.start_with?('test_waits.allow:1:') }, line)
    end
    twice = "platform/app/test/a_test.exs sleep 1 a\nplatform/app/test/a_test.exs sleep 1 b\n"
    assert(errors(twice).any? { |e| e.start_with?('test_waits.allow:2:') })
  end

  def test_comments_and_blank_lines_in_the_allowlist
    write('platform/app/test/a_test.exs', "assert true\n")
    assert_equal [], errors("# a note\n\n")
  end
end
