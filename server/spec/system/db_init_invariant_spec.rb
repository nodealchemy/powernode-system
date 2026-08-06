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
# `type: :lib` is explicit and load-bearing. rails_helper enables
# `infer_spec_type_from_file_location!`, which maps spec/system/** to
# `type: :system` — RSpec's BROWSER system tests, which require capybara.
# Capybara is not in the Gemfile, so the inferred type made this file raise
# `Gem::LoadError` at LOAD time, and a load error in one file aborts the whole
# run: `rspec <spec-root>` printed "0 examples, 0 failures" and exited non-zero,
# which reads as green to anything checking a piped exit code.
#
# The directory name is the trap: this extension is called "system", so
# spec/system/ looks like "specs for the system extension" while RSpec hears
# "browser tests". Nothing here drives a browser — it reads a shipped script and
# asserts on its contents.
RSpec.describe "hub-backend DB-init invariant (imp 019f77c5)", type: :lib do
  # Anchored to THIS FILE, not Rails.root. `Rails.root.join("..", "modules")`
  # only resolves when the extension is the loaded app; under the mounted layout
  # that CI and scripts/validate.sh use, Rails.root is the PLATFORM's server/, so
  # `..` is the platform root and modules/ is not there. That bug survived
  # because the capybara load-abort meant these examples had never once run —
  # un-deading the file is what exposed it. From spec/system/: .. = spec,
  # ../.. = server, ../../.. = the extension root, which owns modules/.
  rails_start = File.expand_path(
    "../../../modules/powernode-hub-backend/rootfs/usr/local/bin/rails-start.sh", __dir__
  )

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
