# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"

# Audit F8-09 — the registry-integrity gate only validated docs call-sites
# (platform.X() in markdown) against the registry; it never compared the tool
# classes' DISPATCHED actions (when "...") to the registry, so it reported
# "0 unknown" while 8 implemented SystemFleetTool actions were unregistered
# (F8-01). These specs pin the new second pass: it must catch an action that
# is dispatched in an extension tool but absent from the registry.
RSpec.describe "check-mcp-actions.sh dispatcher pass (F8-09)" do
  # __dir__ = extensions/system/server/spec/scripts → up 3 = extensions/system
  ext_root = File.expand_path("../../..", __dir__)
  let(:script) { File.join(ext_root, "docs/.verify/check-mcp-actions.sh") }
  let(:tools_dir) { File.join(ext_root, "server/app/services/ai/tools") }

  def run(env: {})
    Open3.capture2e(env, "bash", script)
  end

  it "exits 0 on the real tree (every dispatched action is registered)" do
    _out, status = run
    expect(status.exitstatus).to eq(0)
  end

  it "exits nonzero when a dispatched action has no registry entry" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(Dir.glob("#{tools_dir}/*.rb"), dir)
      # Inject an orphan dispatcher branch into a copied tool file.
      orphan_file = File.join(dir, "system_fleet_tool.rb")
      body = File.read(orphan_file)
      body = body.sub(
        /when "system_get_node"/,
        %(when "system_zzz_orphan_action" then noop\n        when "system_get_node")
      )
      File.write(orphan_file, body)

      out, status = run(env: { "MCP_TOOLS_DIR" => dir })

      expect(status.exitstatus).not_to eq(0),
        "expected the dispatcher pass to flag the unregistered action; output:\n#{out}"
      expect(out).to include("system_zzz_orphan_action")
    end
  end
end
