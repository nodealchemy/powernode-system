# frozen_string_literal: true

require "rails_helper"
require "json"
require "open3"
require "tmpdir"

# Design step 3 (docs/reference/ci-spec-suite-parallelisation-design-2026-09-05.md §5).
#
# WHY SHARDING AT ALL, and why this could not be solved with a bigger timeout:
# the sequential suite is ~217 minutes of work while the job container's own
# entrypoint is /bin/sleep 10800 = 180 minutes. The single rspec job therefore
# cannot finish, ever — raising timeout-minutes past 180 only trades a legible
# timeout for an opaque container death. Run 1780 is the demonstration: 2153 +
# 8435 examples ran, two suites never started, job killed at its ceiling.
#
# The partition is computed independently by every shard from the same commit,
# so it needs no artifact, cache or job output — but that only holds if it is a
# PURE FUNCTION of the plan. These examples pin that.
RSpec.describe "scripts/ci-spec-shard.rb" do
  let(:script) { File.expand_path("../../../scripts/ci-spec-shard.rb", __dir__) }

  # Mirrors rspec --dry-run --format json: `id` carries the INCLUDING spec
  # file, `file_path` may be a shared-example file (§5.4).
  def plan(entries)
    { "examples" => entries.map { |id, fp| { "id" => id, "file_path" => fp || id.split("[").first } } }
  end

  def write_plan(dir, entries)
    path = File.join(dir, "plan.json")
    File.write(path, JSON.generate(plan(entries)))
    path
  end

  def shard(plan_path, shards:, index:)
    out, err, status = Open3.capture3(
      "ruby", script, plan_path, "--shards", shards.to_s, "--index", index.to_s
    )
    [ out.split("\n").reject(&:empty?), err, status ]
  end

  def examples_for(files, counts)
    files.sum { |f| counts.fetch(f) }
  end

  describe "partitioning" do
    # 6 files, sizes 100/90/80/70/60/50 => LPT over 3 shards gives 150/150/150.
    let(:counts) do
      { "./spec/a_spec.rb" => 100, "./spec/b_spec.rb" => 90, "./spec/c_spec.rb" => 80,
        "./spec/d_spec.rb" => 70,  "./spec/e_spec.rb" => 60, "./spec/f_spec.rb" => 50 }
    end
    let(:entries) do
      counts.flat_map { |file, n| Array.new(n) { |i| [ "#{file}[1:#{i + 1}]", file ] } }
    end

    it "covers every file exactly once across all shards" do
      Dir.mktmpdir do |dir|
        path = write_plan(dir, entries)
        all = (0...3).flat_map { |i| shard(path, shards: 3, index: i).first }

        expect(all.sort).to eq(counts.keys.sort)
        expect(all.uniq.length).to eq(all.length), "a file landed in two shards"
      end
    end

    it "balances by example count, not by file count" do
      Dir.mktmpdir do |dir|
        path = write_plan(dir, entries)
        loads = (0...3).map { |i| examples_for(shard(path, shards: 3, index: i).first, counts) }

        expect(loads).to all(eq(150)),
          "LPT over 100/90/80/70/60/50 must give three equal 150s, got #{loads.inspect}"
      end
    end

    it "is a pure function of the plan — same input, same answer" do
      Dir.mktmpdir do |dir|
        path = write_plan(dir, entries)
        first  = (0...3).map { |i| shard(path, shards: 3, index: i).first }
        second = (0...3).map { |i| shard(path, shards: 3, index: i).first }

        expect(second).to eq(first),
          "every shard computes the partition independently; a non-deterministic " \
          "answer silently drops or double-runs files"
      end
    end

    it "is stable against plan ORDER, since rspec makes no ordering promise" do
      Dir.mktmpdir do |dir|
        a = write_plan(dir, entries)
        b = File.join(dir, "shuffled.json")
        File.write(b, JSON.generate(plan(entries.shuffle)))

        expect((0...3).map { |i| shard(b, shards: 3, index: i).first })
          .to eq((0...3).map { |i| shard(a, shards: 3, index: i).first })
      end
    end
  end

  # §5.4: the JSON formatter attributes an it_behaves_like example to the
  # SHARED-EXAMPLE file. Handing that file to a shard makes rspec load it, run
  # zero examples, and fail the count assertion — after wasting the shard.
  describe "shared examples" do
    it "attributes examples to the including spec, never the shared-example file" do
      entries = [
        [ "./spec/services/providers/aws_provider_spec.rb[1:1]", "./spec/services/providers/shared_examples.rb" ],
        [ "./spec/services/providers/aws_provider_spec.rb[1:2]", "./spec/services/providers/shared_examples.rb" ],
        [ "./spec/services/providers/gcp_provider_spec.rb[1:1]", "./spec/services/providers/shared_examples.rb" ]
      ]

      Dir.mktmpdir do |dir|
        path = write_plan(dir, entries)
        all  = (0...2).flat_map { |i| shard(path, shards: 2, index: i).first }

        expect(all).to contain_exactly(
          "./spec/services/providers/aws_provider_spec.rb",
          "./spec/services/providers/gcp_provider_spec.rb"
        )
        expect(all).not_to include(a_string_matching(/shared_examples/)),
          "a shared-example file is not runnable on its own"
      end
    end
  end

  describe "guard rails" do
    let(:entries) { [ [ "./spec/a_spec.rb[1:1]", nil ] ] }

    it "refuses an index outside the shard count" do
      Dir.mktmpdir do |dir|
        path = write_plan(dir, entries)
        _out, err, status = shard(path, shards: 3, index: 3)

        expect(status).not_to be_success
        expect(err).to match(/index/i)
      end
    end

    it "refuses a plan with no examples rather than emitting an empty shard" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "empty.json")
        File.write(path, JSON.generate({ "examples" => [] }))
        _out, err, status = shard(path, shards: 3, index: 0)

        expect(status).not_to be_success
        expect(err).to match(/no examples/i),
          "an empty plan means the dry run failed; emitting empty shards would " \
          "turn that into a green run that tested nothing"
      end
    end
  end
end
