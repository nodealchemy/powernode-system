#!/usr/bin/env ruby
# frozen_string_literal: true

# Syntax-checks the shell in every `run:` block of the given workflow files.
#
#   ruby scripts/ci-lint-workflow-shell.rb [file-or-dir ...]   # default: .gitea/workflows
#
# WHY. 52a5e06c (2026-09-17) put an apostrophe inside the single-quoted
# `docker exec bash -c '...'` script of both UKI build steps. bash failed each
# step with "syntax error near unexpected token `)'" before any image was
# built, and every disk-image build failed for 11 days before anyone noticed.
# YAML parses such a block happily; only bash can say it is not a script.
#
# HOW. Each `run:` string has its ${{ ... }} expressions replaced by a fixed
# token (they are resolved by the runner before bash ever sees the text, and
# can contain quotes and braces that would themselves read as syntax errors),
# then goes through `bash -n` (parse only, executes nothing). Steps that
# declare a non-bash `shell:` are skipped and counted, not guessed at.
#
# Deliberately uses only Ruby's stdlib and bash: the ruby-syntax CI job already
# has Ruby, and nothing here depends on yq (the Python and Go yqs differ) or on
# a tool the runner image may not ship.
#
# KNOWN LIMIT: the ${{ }} matcher is non-greedy, so a literal `}}` inside an
# expression's own string argument ends the match early. None exist in this
# tree; the failure mode is a false red, never a false green.
#
# EXIT: 0 clean | 1 at least one run: block failed to parse | 2 could not lint
# (unparseable YAML, no workflow files found, bash missing). An empty glob or a
# broken file must never read as "clean".

require "yaml"
require "date"
require "tempfile"
require "open3"

EXPRESSION = /\$\{\{.*?\}\}/m
TOKEN      = "GHA_EXPR"
BASH_LIKE  = %r{\A(?:/\S*/)?(bash|sh)(\s|\z)}i

def workflow_files(args)
  args = [ ".gitea/workflows" ] if args.empty?
  args.flat_map do |arg|
    File.directory?(arg) ? Dir.glob(File.join(arg, "*.{yaml,yml}")).sort : [ arg ]
  end
end

# nil when the document has no `jobs` mapping at all (typo'd key, empty file):
# that is "nothing was linted", which must not read as clean.
def steps_of(doc)
  jobs = doc.is_a?(Hash) ? doc["jobs"] : nil
  return nil unless jobs.is_a?(Hash)

  workflow_shell = doc.dig("defaults", "run", "shell")

  jobs.flat_map do |job_name, job|
    next [] unless job.is_a?(Hash) && job["steps"].is_a?(Array)

    default_shell = job.dig("defaults", "run", "shell")
    job["steps"].each_with_index.map do |step, i|
      next unless step.is_a?(Hash) && step["run"].is_a?(String)

      {
        job: job_name,
        label: step["name"] || "step ##{i + 1}",
        shell: (step["shell"] || default_shell || workflow_shell).to_s,
        script: step["run"]
      }
    end.compact
  end
end

def bash_syntax_error(script)
  Tempfile.create([ "wf-run", ".sh" ]) do |f|
    f.write(script.gsub(EXPRESSION, TOKEN))
    f.flush
    _out, err, status = Open3.capture3("bash", "-n", f.path)
    # `bash -n` only WARNS (exit 0) on a heredoc with no terminator, which is
    # exactly what a YAML indentation slip produces; treat the warning as fatal.
    if !status.success? || err.match?(/here-document.*delimited by end-of-file/)
      err.gsub(f.path, "<run block>").strip
    end
  end
end

files = workflow_files(ARGV)
if files.empty?
  warn "ci-lint-workflow-shell: no workflow files found in #{ARGV.inspect.then { |a| a == '[]' ? '.gitea/workflows' : a }}"
  exit 2
end

begin
  _, _, probe = Open3.capture3("bash", "-c", "exit 0")
  raise "bash exited #{probe.exitstatus}" unless probe.success?
rescue StandardError => e
  warn "ci-lint-workflow-shell: bash is not runnable (#{e.message})"
  exit 2
end

checked = skipped = 0
failures = []
unreadable = []

files.each do |file|
  begin
    doc = YAML.safe_load(File.read(file), permitted_classes: [ Date, Time ], aliases: true)
  rescue StandardError => e
    unreadable << "#{file}: #{e.class}: #{e.message.lines.first.to_s.strip}"
    next
  end

  steps = steps_of(doc)
  if steps.nil?
    unreadable << "#{file}: no `jobs:` mapping (empty file or mistyped key), nothing was linted"
    next
  end

  steps.each do |step|
    unless step[:shell].empty? || step[:shell].match?(BASH_LIKE)
      skipped += 1
      next
    end

    checked += 1
    if (err = bash_syntax_error(step[:script]))
      failures << "#{file}: job #{step[:job]} / step #{step[:label].inspect}: bash -n: #{err}"
    end
  end
end

if checked.zero? && skipped.zero? && unreadable.empty?
  warn "ci-lint-workflow-shell: no run: blocks found in #{files.size} file(s); refusing to report clean"
  exit 2
end

puts "ci-lint-workflow-shell: #{files.size} file(s), #{checked} run block(s) checked, #{skipped} skipped (non-bash shell)"

unreadable.each { |u| warn "UNPARSEABLE #{u}" }
failures.each   { |f| warn "SYNTAX ERROR #{f}" }

exit 2 if unreadable.any?
exit 1 if failures.any?
exit 0
