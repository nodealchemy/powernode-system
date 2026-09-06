#!/usr/bin/env ruby
# frozen_string_literal: true

# Partition the spec suite into N balanced shards, deterministically.
#
# WHY THIS EXISTS. The sequential suite is ~217 minutes of work, while the CI
# job container's own entrypoint is /bin/sleep 10800 = 180 minutes. One job
# running everything therefore cannot finish — no timeout-minutes value helps,
# because past 180 the container dies instead of the step. Run 1780 is the
# demonstration: two suites ran (2153 + 8435 examples), two never started, and
# the job was killed at its ceiling.
#
# NO ARTIFACT, NO CACHE, NO JOB OUTPUT. Every shard computes the same partition
# from the same commit, so the answer must be a PURE FUNCTION of the plan —
# stable under plan order, identical on every invocation. If it were not, two
# shards would silently run the same file while another ran nothing.
#
# Usage: ci-spec-shard.rb <plan.json> --shards N --index I
#   plan.json is `rspec --dry-run --format json --out plan.json <dirs>`.
#   Prints this shard's spec files, one per line.

require 'json'

def die(message)
  warn("ci-spec-shard: #{message}")
  exit 1
end

path   = ARGV[0]
shards = nil
index  = nil

ARGV.each_with_index do |arg, i|
  shards = ARGV[i + 1].to_i if arg == '--shards'
  index  = ARGV[i + 1].to_i if arg == '--index'
end

die('usage: ci-spec-shard.rb <plan.json> --shards N --index I') if path.nil? || shards.nil? || index.nil?
die("plan not found: #{path}") unless File.file?(path)
die("--shards must be >= 1, got #{shards}") if shards < 1
die("--index #{index} is outside 0...#{shards}") if index.negative? || index >= shards

plan =
  begin
    JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    die("plan is not valid JSON (#{e.message}) — the dry run probably failed")
  end

examples = plan['examples']
if !examples.is_a?(Array) || examples.empty?
  die('plan contains no examples — the dry run failed, and emitting empty shards ' \
      'would turn that into a green run that tested nothing')
end

# Group by the INCLUDING spec file, taken from the id's path prefix.
#
# The JSON formatter reports file_path as the SHARED-EXAMPLE file for anything
# pulled in via it_behaves_like (providers/shared_examples.rb and friends).
# Grouping on file_path would hand a shared-example file to a shard as if it
# were runnable: rspec loads it, runs zero examples, and the shard's count
# assertion fails — after the shard has already been spent. The id always
# carries the including spec, so group on that.
counts = Hash.new(0)
examples.each do |example|
  id = example['id'].to_s
  file = id.split('[').first
  file = example['file_path'].to_s if file.empty?
  next if file.empty?

  counts[file] += 1
end

die('plan yielded no spec files') if counts.empty?

# LPT: heaviest first, each onto the currently-lightest shard. Ties broken by
# path, then by shard index, so the result does not depend on hash ordering or
# on the order rspec happened to emit examples in.
ordered = counts.sort_by { |file, count| [-count, file] }
loads   = Array.new(shards, 0)
buckets = Array.new(shards) { [] }

ordered.each do |file, count|
  target = (0...shards).min_by { |i| [loads[i], i] }
  buckets[target] << file
  loads[target] += count
end

puts buckets[index].sort
