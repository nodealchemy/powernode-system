# frozen_string_literal: true

require "spec_helper"

# IMP-29914cc57313 — operator-facing half of IMP-65bea54e4081 (extensions/system
# c37f5ad0, which corrected the MCP surface only).
#
# Promoting a NodeModuleVersion advances `promotion_state` and at most one
# timestamp column. It does NOT change which artifact a node receives: the
# node-facing download resolves NodeModule#current_version_id
# (Api::V1::System::NodeApi::ModulesController#download reads
# `@module.current_version&.artifact`; FilesController#module_file is
# identical), and no node-facing surface reads promotion_state at all.
#
# Four docs taught the opposite — most sharply module-authoring.md's
# troubleshooting row ("agents only pull `blessed`+", remedy: promote) and its
# "blessed -> live (rolls out fleet-wide)" comment. An operator following those
# promotes, sees success, and the symptom persists with no signal as to why.
#
# This guard has two halves and needs both:
#
#   1. The CODE half pins the premise. If a future change makes the serve path
#      consult promotion_state, these examples redden and the docs corrected
#      here are the ones to revisit. Without it the doc half is a spelling test.
#   2. The DOC half is deliberately a matched PAIR per file — the false claim
#      must be ABSENT and a working replacement PRESENT. Absence alone is
#      vacuous: deleting the troubleshooting row outright would satisfy it,
#      which leaves an operator with a real problem and nothing to do about it.
#
# What it does NOT catch: prose elsewhere in these files, the belief restated
# in wording none of these regexes match, or the same error appearing in a doc
# not listed here. It is a regression pin on four known statements, not a
# semantic check.
#
# Whether the promotion ladder SHOULD gate what the fleet serves is an open
# lifecycle-gating question owned by IMP-c7d618b0b72f. This spec asserts
# current behaviour only.
RSpec.describe "module-promotion docs vs. what the node-facing serve path reads" do
  ext_root = File.expand_path("../../..", __dir__)

  def self.read(ext_root, rel)
    path = File.join(ext_root, rel)
    raise "expected #{rel} to exist under #{ext_root}" unless File.exist?(path)

    File.read(path)
  end

  # --- code: the premise the docs describe -------------------------------

  describe "the node-facing serve path" do
    let(:modules_controller) do
      self.class.read(ext_root, "server/app/controllers/api/v1/system/node_api/modules_controller.rb")
    end
    let(:files_controller) do
      self.class.read(ext_root, "server/app/controllers/api/v1/system/node_api/files_controller.rb")
    end
    let(:node_api_serializer) do
      self.class.read(ext_root, "server/app/serializers/system/node_module_node_api_serializer.rb")
    end

    it "resolves the artifact from NodeModule#current_version, not from a promotion state" do
      # Matched as an ASSIGNMENT, not a bare substring: a comment mentioning
      # `current_version&.artifact` would satisfy the loose form while the code
      # resolved something else.
      expect(modules_controller).to match(/^\s*artifact = @module\.current_version&\.artifact$/)
      expect(files_controller).to match(/^\s*artifact = node_module\.current_version&\.artifact$/)
    end

    it "never consults promotion_state on any surface a node reads" do
      # node_api/module_versions_controller.rb is deliberately excluded: it is
      # the endpoint by which the AGENT REPORTS a commit (it writes a row at
      # promotion_state "built"), not a gate on what the agent is served.
      [ modules_controller, files_controller, node_api_serializer ].each do |src|
        expect(src).not_to include("promotion_state")
      end
    end

    it "never gates on the promotion ladder by predicate or scope either" do
      # The literal-string check above is not sufficient on its own. The review
      # of IMP-29914cc57313 found the mutant it misses: NodeModuleVersion
      # defines built?/staging?/blessed?/live?/retired? via define_method and
      # the matching scopes, so `current_version&.live?` or
      # `versions.blessed.last&.artifact` would gate the serve path on the
      # ladder without the word "promotion_state" appearing anywhere.
      ladder = /(?:\.(?:built|staging|blessed|live|retired)\?)|(?:versions\.(?:built|staging|blessed|live|retired)\b)/
      [ modules_controller, files_controller, node_api_serializer ].each do |src|
        expect(src).not_to match(ladder)
      end
    end
  end

  # --- docs: the belief must be gone AND a working remedy present ---------

  describe "docs/runbooks/module-authoring.md" do
    let(:doc) { self.class.read(ext_root, "docs/runbooks/module-authoring.md") }

    it "no longer claims agents only pull blessed+, nor that promotion rolls out fleet-wide" do
      expect(doc).not_to match(/agents? only pull/i)
      expect(doc).not_to match(/rolls out fleet-wide/i)
    end

    # Scoped to the ROW and to the SECTION it defers to, never to the file. A
    # file-level presence check passed with the row deleted outright, because
    # the prose below the same table also names both — i.e. it was vacuous
    # against exactly the mutant this pair exists to catch.
    let(:pull_row) do
      doc[/^\| Assignment to template succeeds but agent doesn't pull \|.*$/] ||
        raise("could not locate the \"agent doesn't pull\" troubleshooting row in module-authoring.md")
    end

    let(:diagnosis_section) do
      doc[/^### Why the agent isn't pulling$.*?(?=^## )/m] ||
        raise("could not locate the \"Why the agent isn't pulling\" section in module-authoring.md")
    end

    it "names the pointer the agent actually resolves and sends the operator somewhere" do
      expect(pull_row).to include("current_version_id")
      expect(pull_row).to include("#why-the-agent-isnt-pulling")
    end

    it "gives a remedy that works, and says where it does not" do
      expect(diagnosis_section).to include("system_rollback_module_version")
      # The review of IMP-29914cc57313 caught the replacement remedy being
      # refused for one of the causes it was offered for: rollback_usable?
      # applies the same non-empty floor that withheld the promotion. A remedy
      # that fails silently for one branch is the defect this task exists to
      # fix, so the caveat and its alternative are pinned, not just the verb.
      expect(diagnosis_section).to include("rollback_usable?")
      expect(diagnosis_section).to include("system.module_publish.min_artifact_bytes")
    end

    # IMP-b7abf6c777da removed the mechanism cause 2 blamed: an ordinary
    # VERSIONED_ATTRIBUTES save still mints a version row, but no longer points
    # current_version_id at it. Both halves are pinned, because dropping the
    # false sentence alone would leave the row with no writer named at all and
    # send an operator looking at the wrong one. Region-scoped to the
    # diagnosis section; a file-level check is vacuous here (the same words
    # appear in the ladder discussion below it).
    it "does not blame the auto-version callback for moving the pointer, and names what does" do
      expect(diagnosis_section).not_to match(
        /creates a new version row and points\s+`?current_version_id`? at it/i
      )
      expect(diagnosis_section).to match(/ordinary spec edit is no longer a cause/i)
      expect(diagnosis_section).to include("import_manifest")
      expect(diagnosis_section).to include("package build webhook")
    end
  end

  describe "docs/FLEET_SENSORS.md" do
    let(:doc) { self.class.read(ext_root, "docs/FLEET_SENSORS.md") }

    # The module_promotion_sensor block only; the file documents ~20 sensors.
    let(:promotion_sensor_block) do
      doc[/^### `module_promotion_sensor`.*?(?=^### )/m] ||
        raise("could not locate the module_promotion_sensor section in FLEET_SENSORS.md")
    end

    it "does not present promotion alone as the remediation" do
      expect(promotion_sensor_block).not_to match(
        /Recommended remediation:\*\* None automated — operator promotes via UI or/
      )
    end

    it "says what promotion does not do, and names the action that moves the fleet" do
      expect(promotion_sensor_block).to include("current_version_id")
      expect(promotion_sensor_block).to include("system_rollback_module_version")
    end

    # 426 lines below the sensor block, and outside promotion_sensor_block's
    # reach — the same false belief restated as an intervention-policy blurb.
    # Found by the independent review, not by the sweep that wrote this spec.
    it "does not describe the module_promote_to_live policy as promoting across the fleet" do
      row = doc[/^\| `system\.module_promote_to_live` \|.*$/] ||
            raise("could not locate the system.module_promote_to_live policy row in FLEET_SENSORS.md")

      expect(row).not_to match(/promotes module across the fleet/i)
      expect(row).to match(/does \*\*not\*\* change which version the fleet serves/i)
    end
  end

  describe "docs/tutorials/02-first-module.md" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/02-first-module.md") }

    it "no longer says promoting to live makes the version eligible for fleet-wide rollout" do
      expect(doc).not_to match(/eligible for fleet-wide rollout/i)
    end

    it "states that promotion does not move what the fleet serves" do
      expect(doc).to include("current_version_id")
    end
  end

  describe "docs/tutorials/06-rolling-upgrade.md" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/06-rolling-upgrade.md") }

    it "no longer states a promotion state as a prerequisite the executor enforces" do
      expect(doc).not_to match(/promoted to `blessed` or `live`/i)
    end

    it "says what RollingModuleUpgradeExecutor actually requires of the target version" do
      # Not a bare /promotion_state/ — the file already prints that key in a
      # sample response, so the loose form passed against the uncorrected doc.
      expect(doc).to match(/`promotion_state` is not checked by/)
      expect(doc).to include("oci_digest")
    end
  end

  # Both found by the independent review's sweep, not by the one that wrote
  # this spec: the belief restated as a tutorial PREREQUISITE, and the
  # architecture doc presenting the ladder as the whole module lifecycle with
  # no mention of the pointer a node actually resolves.
  describe "docs/tutorials/09-honeypot-canary.md" do
    let(:doc) { self.class.read(ext_root, "docs/tutorials/09-honeypot-canary.md") }

    it "does not list a promotion state as a prerequisite for the module to reach the node" do
      expect(doc).not_to match(/promoted ≥ blessed/i)
      expect(doc).to include("current_version_id")
    end
  end

  describe "docs/ARCHITECTURE.md" do
    let(:doc) { self.class.read(ext_root, "docs/ARCHITECTURE.md") }

    let(:promotion_lifecycle) do
      doc[/\*\*Promotion lifecycle\*\*.*?```mermaid/m] ||
        raise("could not locate the Promotion lifecycle paragraph in ARCHITECTURE.md")
    end

    it "says the ladder does not determine what a node receives" do
      expect(promotion_lifecycle).to include("current_version_id")
      expect(promotion_lifecycle).to include("system_rollback_module_version")
    end
  end

  describe "docs/MCP_API_REFERENCE.md" do
    let(:doc) { self.class.read(ext_root, "docs/MCP_API_REFERENCE.md") }

    let(:promote_row) do
      doc[/^\| `system_promote_module_version` \|.*$/] ||
        raise("could not locate the system_promote_module_version row in MCP_API_REFERENCE.md")
    end

    it "qualifies the promote row so the table does not read as a ship action" do
      expect(promote_row).to match(/does not change which version the fleet serves/i)
      # Paired, like the other files: the qualifier alone leaves the row saying
      # what does NOT work with no pointer to what does.
      expect(promote_row).to include("system_rollback_module_version")
    end
  end
end
