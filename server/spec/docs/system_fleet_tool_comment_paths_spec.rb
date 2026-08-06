# frozen_string_literal: true

require "spec_helper"

# IMP-b65ecef29263 — the ACTION_PERMISSIONS header comment pointed auditors at
# db/migrate/20260429120000_seed_system_extension_permissions_and_flags.rb,
# which the migration squash deleted; the authoritative catalog moved to the
# Permissions.register_catalog block in lib/powernode_system/engine.rb. A
# permission map whose provenance comment names a dead file sends every
# auditor to a 404 — and the wrong-family template gates survived review
# partly because of it. Pinned generally: every repo file path a comment in
# this tool names must exist on disk.
RSpec.describe "SystemFleetTool comment path references" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:tool_source) do
    File.read(File.join(extension_root, "server/app/services/ai/tools/system_fleet_tool.rb"))
  end

  it "names only files that exist when a comment cites a repo path" do
    referenced = tool_source.each_line.select { |l| l.strip.start_with?("#") }
                            .flat_map { |l| l.scan(%r{(?:extensions/system/)?((?:server|lib|db|docs)/[\w\-./]+\.rb)}) }
                            .flatten.uniq
    # A cited path may live in the extension or in the parent platform tree
    # (e.g. core's server/config/permissions.rb) — both are real references.
    platform_root = File.expand_path("../..", extension_root)
    missing = referenced.reject do |rel|
      File.exist?(File.join(extension_root, rel)) || File.exist?(File.join(platform_root, rel))
    end
    expect(missing).to be_empty,
      "comments in system_fleet_tool.rb cite nonexistent files: #{missing.inspect}"
  end
end
