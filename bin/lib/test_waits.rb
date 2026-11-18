# frozen_string_literal: true

# Real-timer waits in tests (bin/check test-waits). A test waits on an event, a record or a
# `DOWN` (platform/frameworks/test_await), never on the clock. Under platform/ and products/,
# a test file (any .ex/.exs under a test/ folder, or a *_test.exs) may not contain:
#
#   sleep            Process.sleep(…) or :timer.sleep(…), except (:infinity), which holds a
#                    stand-in process until it is killed and waits for nothing
#   receive_timeout  assert_receive/refute_receive with a timeout below THRESHOLD ms: a
#                    literal, a module attribute of the file, or none (ExUnit's 100 ms; a bare
#                    assert_receive is fine where the project's test_helper.exs raises the
#                    default to THRESHOLD or more, as AtlasTestAwait.exunit_options/1 does)
#   after_timeout    `after N ->` with 0 < N < THRESHOLD: a receive used as a sleep or a
#                    polling interval (`after 0` only flushes and is fine)
#
# Exceptions are listed in test_waits.allow, one per line:
#   PATH  RULE  COUNT  REASON
# The count is exact: a file with more hits has a new wait; one with fewer must lower or drop
# its line (a ratchet). Every line needs a reason. A line for a file that is gone is stale.

require 'find'

# Sources are UTF-8 whatever the locale (CI's and a sandbox's may be C).
Encoding.default_external = Encoding::UTF_8

module TestWaits
  THRESHOLD = 1000
  ROOTS = %w[platform products].freeze
  PRUNE = %w[deps _build node_modules .elixir_ls .git tmp].freeze
  RULES = %w[sleep receive_timeout after_timeout].freeze
  Hit = Struct.new(:path, :line, :rule, :detail)

  module_function

  def test_file?(relative)
    return false unless relative.end_with?('.ex', '.exs')

    relative.split('/').include?('test') || relative.end_with?('_test.exs')
  end

  def files(root)
    found = []
    ROOTS.each do |top|
      base = File.join(root, top)
      next unless File.directory?(base)

      Find.find(base) do |path|
        if File.directory?(path)
          Find.prune if PRUNE.include?(File.basename(path))
          next
        end
        relative = path.delete_prefix("#{root}/")
        found << relative if test_file?(relative)
      end
    end
    found.sort
  end

  # The code of a line without its comment: `#` that starts a comment, not `#{`.
  def code(line)
    line.sub(/(?:^|(?<=\s))#(?!\{).*$/, '')
  end

  def attributes(source)
    source.scan(/^\s*@(\w+)\s+([\d_]+)\s*$/).to_h { |name, value| [name, Integer(value.delete('_'))] }
  end

  # The text of a call's arguments from `start` (just after the macro name): to the matching
  # parenthesis, or for a call without them, to the end of its last line.
  def arguments(text, start)
    i = start
    i += 1 while text[i] == ' '
    if text[i] == '('
      depth = 0
      j = i
      while j < text.size
        depth += 1 if '([{'.include?(text[j])
        depth -= 1 if ')]}'.include?(text[j])
        return text[(i + 1)...j] if depth.zero?

        j += 1
      end
      return text[(i + 1)..]
    end
    depth = 0
    j = i
    while j < text.size
      c = text[j]
      depth += 1 if '([{'.include?(c)
      depth -= 1 if ')]}'.include?(c)
      break if depth.negative?
      break if c == "\n" && depth.zero? && !text[i...j].rstrip.end_with?(',')
      break if depth.zero? && text[j..].start_with?(' do') && text[j + 3].to_s.match?(/[\s\n]/)

      j += 1
    end
    text[i...j]
  end

  # Top-level comma-separated arguments.
  def split(args)
    parts = []
    depth = 0
    current = +''
    in_string = false
    args.each_char.with_index do |c, k|
      in_string = !in_string if c == '"' && args[k - 1] != '\\'
      unless in_string
        depth += 1 if '([{'.include?(c)
        depth -= 1 if ')]}'.include?(c)
        if c == ',' && depth.zero?
          parts << current.strip
          current = +''
          next
        end
      end
      current << c
    end
    parts << current.strip unless current.strip.empty?
    parts
  end

  def timeout(arg, attrs)
    case arg
    when nil then nil
    when /\A[\d_]+\z/ then Integer(arg.delete('_'))
    when /\A@(\w+)\z/ then attrs.fetch(Regexp.last_match(1), :unknown)
    when /\A:infinity\z/ then Float::INFINITY
    else :unknown
    end
  end

  def scan(relative, source, raised_default)
    hits = []
    stripped = source.lines.map { |l| code(l) }.join
    attrs = attributes(stripped)
    line_of = ->(offset) { stripped[0...offset].count("\n") + 1 }

    stripped.scan(/(?:\bProcess|(?<![\w:]):timer)\.sleep\(\s*([^)\s]*)/) do
      next if Regexp.last_match(1) == ':infinity'

      hits << Hit.new(relative, line_of.(Regexp.last_match.begin(0)), 'sleep', Regexp.last_match(0))
    end

    stripped.to_enum(:scan, /\b(assert|refute)_receive\b(?!d)/).each do
      m = Regexp.last_match
      args = split(arguments(stripped, m.end(0)))
      value = timeout(args[1], attrs)
      implicit = value.nil?
      value = (m[1] == 'assert' && raised_default ? THRESHOLD : 100) if implicit
      next if value.is_a?(Numeric) && value >= THRESHOLD

      detail = implicit ? "#{m[0]} without a timeout (100 ms)" : "#{m[0]} timeout #{args[1]}"
      hits << Hit.new(relative, line_of.(m.begin(0)), 'receive_timeout', detail)
    end

    stripped.scan(/\bafter\s+([\d_]+)\s*->/) do
      value = Integer(Regexp.last_match(1).delete('_'))
      next if value.zero? || value >= THRESHOLD

      hits << Hit.new(relative, line_of.(Regexp.last_match.begin(0)), 'after_timeout', "after #{value}")
    end

    hits
  end

  # Whether the project (nearest folder with a mix.exs) raises ExUnit's assert_receive default.
  def raised_default?(root, relative, cache)
    dir = File.dirname(relative)
    until dir == '.' || File.exist?(File.join(root, dir, 'mix.exs'))
      dir = File.dirname(dir)
    end
    cache[dir] ||= begin
      helper = File.join(root, dir, 'test', 'test_helper.exs')
      text = File.exist?(helper) ? File.read(helper) : ''
      configured = text[/assert_receive_timeout:\s*([\d_]+)/, 1]
      text.include?('AtlasTestAwait.exunit_options(') ||
        (!configured.nil? && Integer(configured.delete('_')) >= THRESHOLD)
    end
  end

  def allowlist(text)
    entries = {}
    errors = []
    text.each_line.with_index(1) do |line, n|
      next if line.strip.empty? || line.start_with?('#')

      path, rule, count, reason = line.strip.split(/\s+/, 4)
      if !RULES.include?(rule) || count !~ /\A\d+\z/ || reason.to_s.strip.empty?
        errors << "test_waits.allow:#{n}: want `PATH RULE COUNT REASON` (rules: #{RULES.join(', ')})"
      elsif entries.key?([path, rule])
        errors << "test_waits.allow:#{n}: #{path} #{rule} is listed twice"
      else
        entries[[path, rule]] = Integer(count)
      end
    end
    [entries, errors]
  end

  def check(root, allow_text)
    entries, errors = allowlist(allow_text)
    cache = {}
    hits = files(root).flat_map do |relative|
      scan(relative, File.read(File.join(root, relative)), raised_default?(root, relative, cache))
    end
    counts = hits.group_by { |h| [h.path, h.rule] }

    counts.each do |key, list|
      allowed = entries.fetch(key, 0)
      next if list.size == allowed

      if list.size > allowed
        list.each { |h| errors << "#{h.path}:#{h.line}: #{h.rule}: #{h.detail}" }
        errors << "#{key[0]}: #{list.size} #{key[1]} hit(s), #{allowed} allowed: await an event (platform/frameworks/test_await)" if allowed.positive?
      else
        errors << "#{key[0]}: #{list.size} #{key[1]} hit(s), #{allowed} allowed: lower its line in test_waits.allow"
      end
    end
    entries.each do |(path, rule), allowed|
      next if counts.key?([path, rule])

      errors << if File.exist?(File.join(root, path))
                  "#{path}: no #{rule} hit left, #{allowed} allowed: drop its line in test_waits.allow"
                else
                  "#{path}: gone; drop its line in test_waits.allow"
                end
    end
    [errors, hits]
  end
end

if $PROGRAM_NAME == __FILE__
  root = ARGV[0] || File.expand_path('../..', __dir__)
  allow = File.join(__dir__, 'test_waits.allow')
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  errors, hits = TestWaits.check(root, File.exist?(allow) ? File.read(allow) : '')
  elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
  if errors.empty?
    puts "test-waits: no real-timer wait outside the allowlist (#{hits.size} allowed, #{elapsed}s)"
  else
    puts errors
    puts "test-waits: #{errors.size} problem(s); see bin/lib/test_waits.rb"
    exit 1
  end
end
