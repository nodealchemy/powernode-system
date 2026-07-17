# frozen_string_literal: true

require "rails_helper"
require "set"

# inc29 fix (improvement 019f6ef4-f5e0): Api::V1::System::NodeApi::
# ConfigController::CLASS_B_PARENT_MODULES (the modules whose ci_build_context
# is handed PARENT_PAT) MUST stay in sync with scripts/module-build/stage15.sh's
# `needs_parent` case arm — the modules whose Stage-1.5 arm actually clones the
# parent platform repo, and therefore the only ones that consume PARENT_PAT.
# Drift in either direction is a real, silent build break:
#   - a slug in stage15.sh but not the constant → its parent clone auths with an
#     empty token ("remote: Failed to authenticate user") and the build fails;
#   - a slug in the constant but not stage15.sh → a PAT handed to a build that
#     never clones the parent (needless credential exposure).
# Nothing else enforced this coupling; this guard fails loudly the moment the
# two diverge.
RSpec.describe "CLASS_B_PARENT_MODULES <-> stage15.sh needs_parent sync" do
  # extensions/system/server/spec/integration/system → extension root/scripts/…
  let(:stage15_path) do
    File.expand_path("../../../../scripts/module-build/stage15.sh", __dir__)
  end

  # Every module slug on a `<slugs>) needs_parent=1 ...` case arm in stage15.sh.
  # Collected across ALL such lines so a future multi-arm split still parses.
  def needs_parent_modules
    File.read(stage15_path).each_line.flat_map do |line|
      m = line.match(/\A\s*([a-z0-9|\-]+)\)\s*needs_parent=1\b/)
      m ? m[1].split("|") : []
    end
  end

  it "locates a parseable needs_parent case arm in stage15.sh" do
    expect(File).to exist(stage15_path)
    expect(needs_parent_modules).not_to be_empty
  end

  it "matches Api::V1::System::NodeApi::ConfigController::CLASS_B_PARENT_MODULES exactly (no drift)" do
    controller_set = Api::V1::System::NodeApi::ConfigController::CLASS_B_PARENT_MODULES.to_set
    script_set = needs_parent_modules.to_set

    expect(script_set).to(
      eq(controller_set),
      "CLASS_B_PARENT_MODULES and stage15.sh needs_parent have drifted.\n" \
      "  in the constant but NOT stage15.sh: #{(controller_set - script_set).to_a.inspect}\n" \
      "  in stage15.sh but NOT the constant: #{(script_set - controller_set).to_a.inspect}"
    )
  end
end
