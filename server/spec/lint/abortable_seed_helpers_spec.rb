# frozen_string_literal: true

require "rails_helper"
require_relative "../support/abortable_seed_helpers"

# Pins the split load_abortable_seed! makes, in BOTH directions. One arm
# alone cannot be told from the helper's absence: without the exit-0 arm a
# helper that converts every SystemExit passes the abort example and reds
# every seed that stops early on purpose; without the abort arm a helper
# that swallows everything passes the skip example and hides every failed
# seed assertion again.
RSpec.describe AbortableSeedHelpers do
  include described_class

  def seed_file(dir, name, body)
    File.join(dir, name).tap { |path| File.write(path, "# frozen_string_literal: true\n#{body}\n") }
  end

  around do |example|
    Dir.mktmpdir("abortable-seed") { |dir| @dir = dir; example.run }
  end

  it "returns normally when the seed stops early with exit 0 — a graceful skip is a success" do
    path = seed_file(@dir, "skips.rb", 'puts "preconditions absent"; exit 0')

    expect { load_abortable_seed!(path) }.not_to raise_error
  end

  it "raises SeedAborted carrying status 1 and the seed's own message when the seed aborts" do
    path = seed_file(@dir, "fails.rb", 'abort("  ❌ Test 2 FAILED — nothing acquired")')

    expect { load_abortable_seed!(path) }.to raise_error(described_class::SeedAborted) { |e|
      expect(e.status).to eq(1)
      expect(e.message).to eq("  ❌ Test 2 FAILED — nothing acquired")
      expect(e.seed).to eq("fails.rb")
    }
  end

  it "raises for any non-zero exit, not only abort's 1" do
    path = seed_file(@dir, "exits.rb", "exit 3")

    expect { load_abortable_seed!(path) }.to raise_error(described_class::SeedAborted) { |e| expect(e.status).to eq(3) }
  end

  it "never lets a SystemExit escape — the property that keeps the runner alive" do
    path = seed_file(@dir, "fails.rb", "abort('x')")

    begin
      load_abortable_seed!(path)
    rescue StandardError => e
      caught = e
    end
    expect(caught).to be_a(described_class::SeedAborted)
  end

  it "does not touch an ordinary error from the seed" do
    path = seed_file(@dir, "raises.rb", 'raise ArgumentError, "bad input"')

    expect { load_abortable_seed!(path) }.to raise_error(ArgumentError, "bad input")
  end
end
