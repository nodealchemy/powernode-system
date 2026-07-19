# frozen_string_literal: true

require "rails_helper"

# Regression guard for imp 019f77c5 (the ops-hub stamped-without-DDL drift):
# the hub's DB-init boot path MUST use `db:migrate` (which runs every extension
# migration's DDL for real), NEVER a bare `db:schema:load` / `db:setup` /
# `db:prepare`. Those load the core-only schema.rb and assume_migrated-stamp the
# private-extension migrations (timestamped below the core schema version)
# WITHOUT running their DDL → permanent drift. If a schema:load path is ever
# genuinely needed here, it must be paired with the un-assume-private-versions +
# db:migrate step from scripts/prepare-extension-test-db.sh — in which case
# update this guard deliberately.
RSpec.describe "hub-backend DB-init invariant (imp 019f77c5)" do
  rails_start = Rails.root.join("..", "modules", "powernode-hub-backend",
                               "rootfs", "usr", "local", "bin", "rails-start.sh")

  it "ships the rails-start boot script" do
    expect(File.exist?(rails_start)).to be(true)
  end

  context "when rails-start.sh is present" do
    let(:body) { File.read(rails_start) }

    it "initializes the DB with db:migrate" do
      expect(body).to match(/rails\s+db:migrate/)
    end

    it "never uses a bare db:schema:load / db:setup / db:prepare in a command" do
      # Match actual invocations (`rails db:schema:load`), not the explanatory
      # comment block that names them.
      offending = body.lines.grep(/(?:rails|rake|bundle exec rails)\s+.*db:(schema:load|setup|prepare|reset)/)
      expect(offending).to be_empty, "rails-start.sh must not schema:load/db:setup — found: #{offending.inspect}"
    end
  end
end
