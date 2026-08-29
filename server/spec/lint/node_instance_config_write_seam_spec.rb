# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# IMP-68d71157b68e (sweep arm) — no NEW wholesale write of
# System::NodeInstance#config.
#
# StatusController#report was fixed on its own; the sweep found it was one of
# THIRTEEN files doing the same read-modify-write of the whole jsonb document.
# That makes it a convention rather than a bug, and a convention that is only
# written down decays: the four telemetry writers each carry a comment naming
# the endpoint that was clobbering them, and it clobbered them anyway for as
# long as nothing checked.
#
# THE PROPERTY: a NodeInstance's `config` is written one KEY at a time, in
# Postgres, against the current row — System::ConfigDocument#merge_config! /
# #delete_config_keys!. Never `update!(config: <whole document>)`, never
# `update_columns(config: ...)`, never `instance.config["k"] = v; save!`.
#
# WHY A SOURCE SCAN AND NOT A RUNTIME GUARD. A `before_save` that rejected a
# config change would have to distinguish creation, the store_accessor writers
# (`cloud_instance_id=`), and a deliberate reset from a clobber — at runtime,
# on a production write path, where being wrong fails an operator action. The
# hazard is authored, not executed: it enters the tree when someone types the
# read-modify-write. So the check reads source.
#
# LEGITIMATE WHOLE-DOCUMENT WRITES EXIST, and they are recognized by a RULE
# rather than by name: a write inside an object-CREATION block
# (`find_or_create_by! { |x| ... }`, `.new(...).tap { |x| ... }`) targets an
# object with no row behind it yet, so there is nothing to clobber. Skipping
# those structurally is what keeps the census below short enough to stay read.
#
# THE EXEMPTION LIST IS A CENSUS, NOT PERMISSION. `config` is a column on nine
# System models; only NodeInstance has a dozen unaware writers. NON_NODE_INSTANCE
# names the receivers that are provably a DIFFERENT model, each with the model
# it resolves to. It is checked in BOTH directions: an entry that no longer
# matches any live hit fails just as loudly as a new unlisted hit, so the list
# cannot rot into a blanket allow.
RSpec.describe "System::NodeInstance#config write seam", type: :lint do
  # Repo-relative-path#receiver-token, never a line number — the key has to
  # survive a line shift. `self` is path-scoped for exactly this reason: it is
  # NodeInstance in node_instance.rb and PuppetResource in puppet_resource.rb.
  NON_NODE_INSTANCE = {
    "app/models/concerns/system/config_document.rb#self" =>
      "System::NodeInstance — the SEAM itself. #reload_config_attribute! re-reads " \
      "the column after the SQL merge and clears its dirty state; it is the one " \
      "place allowed to assign the whole attribute, because it is assigning what " \
      "the database just returned.",
    # Single-quoted: `#@node_module` in a double-quoted string interpolates the
    # (nil) instance variable, silently truncating the key to the path.
    'app/controllers/api/v1/system/node_modules_controller.rb#@node_module' =>
      "System::NodeModule — operator-edited module config; single writer.",
    "app/services/ai/tools/system_fleet_tool.rb#node_module" =>
      "System::NodeModule — same.",
    "app/services/system/module_build_service.rb#node_module" =>
      "System::NodeModule — build metadata.",
    "app/services/system/honeypot/canary_module_service.rb#node_module" =>
      "System::NodeModule — canary marker.",
    "app/services/system/manifest_import_service.rb#mod" =>
      "System::NodeModule — manifest import rebuilds the module document wholesale " \
      "by design (it IS the import).",
    "app/services/system/module_commit_service.rb#assignment" =>
      "System::NodeModuleAssignment — per-assignment commit record.",
    "app/services/system/restart_after_update.rb#version" =>
      "System::NodeModuleVersion — restart-arm stamp.",
    "app/services/system/node_maintenance_service.rb#node" =>
      "System::Node — the node, not the instance.",
    "app/models/system/module_puppet_assignment.rb#self" =>
      "System::ModulePuppetAssignment — its own store helpers.",
    "app/models/system/puppet_resource.rb#self" =>
      "System::PuppetResource — its own store helpers.",
    "db/seeds/smoke_test_provision.rb#node" =>
      "System::Node — smoke-test seed injecting an operator SSH key.",
    "db/seeds/example_multi_tenant.rb#node" =>
      "System::Node — example seed stamping a provenance key.",
    "db/seeds/powernode_dev_cell.rb#template" =>
      "System::NodeTemplate — dev-cell seed setting boot_mode.",
    "db/seeds/powernode_platform_templates.rb#template" =>
      "System::NodeTemplate — platform template seed; the seed IS the source of " \
      "truth for these knobs."
  }.freeze

  # db/seeds is in scope deliberately: a seed writes the same column against
  # the same live fleet, and it was outside the earlier greps.
  SCAN_GLOBS = %w[app/**/*.rb lib/**/*.rb db/seeds/**/*.rb].freeze

  # ── the scanner ─────────────────────────────────────────────────────────
  #
  # Four shapes, because the last sweep in this campaign missed a site by
  # grepping only two of three. Enumerated rather than inferred:
  #
  #   kwarg    — `x.update!(config: ...)`, `update_columns(config: ...)`,
  #              `update_column(:config, ...)`, `assign_attributes(config: ...)`,
  #              including the multi-line form where `config:` is a later
  #              keyword in the same call.
  #   inplace  — `x.config["k"] = v` / `x.config ||= {}` / `self.config = ...`,
  #              which mutate the loaded document for a later `save!`.
  #   attrs    — `attrs = { config: ... }` handed to a write verb further down.
  #
  # KNOWN LIMIT, stated so it is not mistaken for coverage: a config-bearing
  # attribute hash assembled across several lines and then passed to `update!`
  # is not detected. The `attrs` rule catches the single-line literal only.
  VERB_RE = /
    (?<recv>(?:@?[A-Za-z_]\w*\.)*@?[A-Za-z_]\w*)?\.?
    \b(?<verb>update!|update|update_columns|update_column|assign_attributes)\(
  /x
  INPLACE_RE = /(?<recv>(?:@?[A-Za-z_]\w*\.)*@?[A-Za-z_]\w*)\.config\s*(\[[^\]]*\]\s*)?(\|\|)?=[^=~]/
  SELF_RE    = /\bself\.config\s*(\[[^\]]*\]\s*)?(\|\|)?=[^=~]/
  ATTRS_RE   = /^\s*[@\w]+\s*=\s*\{\s*config:/
  # An object-creation block: the body runs on an object with no row behind it.
  CREATE_VERB_RE  = /\b(find_or_create_by!?|find_or_initialize_by|create_with|new|build)\b/
  CREATE_BLOCK_RE = /#{CREATE_VERB_RE.source}.*\bdo\s*\|\s*(?<var>\w+)\s*\|/o
  # The same thing spelled across lines — `Model.find_or_create_by!(\n  ...\n) do |x|`.
  # Only honoured when a creation verb opened the call within the last few
  # lines, so an ordinary `) do |x|` continuation is not mistaken for one.
  CONT_BLOCK_RE   = /\A\s*\)\s*do\s*\|\s*(?<var>\w+)\s*\|/
  CREATE_LOOKBACK = 6

  def self.scan(root)
    root = Pathname.new(root)
    SCAN_GLOBS.flat_map { |g| Dir.glob(root.join(g).to_s) }.sort.flat_map do |abs|
      rel   = Pathname.new(abs).relative_path_from(root).to_s
      lines = File.readlines(abs)
      found = []

      # (indent, block variable) for each open CREATION block. A write to that
      # variable while the block is open is an initializer, not a clobber: the
      # block body runs before the INSERT.
      creating = []

      lines.each_with_index do |line, idx|
        creating.pop while creating.any? && line.match?(/\A\s{0,#{creating.last[0]}}end\b/)

        # Comments are skipped deliberately: the seam's own doc-comment shows
        # the forbidden idioms verbatim, and a guard that trips on the
        # explanation of the rule is a guard nobody keeps.
        next if line.strip.start_with?("#")

        c = line.match(CREATE_BLOCK_RE)
        if c.nil? && (c = line.match(CONT_BLOCK_RE))
          opened = lines[[ idx - CREATE_LOOKBACK, 0 ].max...idx].any? { |l| l.match?(CREATE_VERB_RE) }
          c = nil unless opened
        end
        if c
          creating << [ line[/\A\s*/].length, c[:var] ]
          next
        end

        open_var = creating.last&.last

        if (m = line.match(VERB_RE))
          window = lines[idx, 4].reject { |l| l.strip.start_with?("#") }.join(" ")
          arg    = window[m.end(0)..].to_s
          if arg.match?(/\A\s*config:\s/) || arg.match?(/[,(]\s*config:\s/) || arg.match?(/\A\s*:config\b/)
            recv = m[:recv] || "self"
            found << { path: rel, line: idx + 1, receiver: recv, shape: "kwarg", source: line.strip } unless recv == open_var
          end
        end

        if (m = line.match(INPLACE_RE))
          found << { path: rel, line: idx + 1, receiver: m[:recv], shape: "inplace", source: line.strip } unless m[:recv] == open_var
        elsif line.match?(SELF_RE)
          found << { path: rel, line: idx + 1, receiver: "self", shape: "inplace", source: line.strip }
        end

        if line.match?(ATTRS_RE)
          found << { path: rel, line: idx + 1, receiver: "(attrs-hash)", shape: "attrs", source: line.strip }
        end
      end

      found.uniq { |h| [ h[:line], h[:shape] ] }
    end
  end

  let(:extension_root) { Pathname.new(File.expand_path("../..", __dir__)) }
  let(:hits) { self.class.scan(extension_root) }
  let(:keys) { hits.map { |h| "#{h[:path]}##{h[:receiver]}" }.uniq }

  it "has no wholesale NodeInstance config write outside the seam" do
    novel = hits.reject { |h| NON_NODE_INSTANCE.key?("#{h[:path]}##{h[:receiver]}") }

    expect(novel).to be_empty, <<~MSG
      Wholesale `config` writes that are not accounted for.

      If the receiver is a System::NodeInstance, convert it:

        instance.merge_config!("your_key" => document)   # replaces that key only
        instance.delete_config_keys!("your_key")         # removes that key only

      A read-modify-write of the whole document erases whatever the node's
      heartbeat wrote in the interval — boot_lkg, module_verify_state,
      sdwan_state and runtime_metrics all live in this column.

      If the receiver is a DIFFERENT model, add it to NON_NODE_INSTANCE above
      with the model it resolves to.

      #{novel.map { |h| "  #{h[:path]}:#{h[:line]}  (#{h[:receiver]}, #{h[:shape]})  #{h[:source]}" }.join("\n")}
    MSG
  end

  it "carries no stale NON_NODE_INSTANCE entries" do
    fixed = NON_NODE_INSTANCE.keys - keys

    expect(fixed).to be_empty, <<~MSG
      NON_NODE_INSTANCE names receivers that no longer write `config` wholesale
      (or whose file moved). Delete those lines — a census nobody prunes stops
      being a decision and becomes permission:

      #{fixed.map { |k| "  #{k}" }.join("\n")}
    MSG
  end

  # ── non-vacuity ─────────────────────────────────────────────────────────
  #
  # A scan that finds nothing anywhere passes both examples above while
  # checking nothing at all. These pin the discriminator to synthetic sources
  # so a regex that silently stops matching fails here first.
  describe "the discriminator itself" do
    def scan_source(body)
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app"))
        File.write(File.join(dir, "app", "probe.rb"), body)
        described_scan(dir)
      end
    end

    def described_scan(dir) = self.class.scan(dir)

    it "flags every forbidden shape" do
      expect(scan_source(<<~RUBY).map { |h| h[:shape] }).to contain_exactly("kwarg", "kwarg", "kwarg", "inplace", "inplace", "attrs")
        instance.update!(config: (instance.config || {}).merge("k" => 1))
        instance.update_columns(config: cfg)
        instance.update!(
          public_ip_address: nil,
          config: cfg
        )
        instance.config["k"] = 1
        instance.config ||= {}
        attrs = { config: (instance.config || {}).merge("k" => 1) }
      RUBY
    end

    it "does not flag the seam, a jsonb merge, or a config READ" do
      expect(scan_source(<<~RUBY)).to be_empty
        instance.merge_config!("k" => 1)
        instance.delete_config_keys!("k")
        ::System::NodeInstance.where(id: instance.id).update_all([
          "config = COALESCE(config, '{}'::jsonb) || ?::jsonb", doc.to_json
        ])
        value = instance.config["k"]
        render_success(config: instance.config)
        instance.update!(status: "running")
      RUBY
    end

    # The creation-block skip is the one rule that can make the guard silently
    # vacuous, so it gets its own three-way pin: it must skip the initializer,
    # it must NOT extend to another receiver in the same block, and it must
    # STOP at the block's end.
    it "skips a creation block, but only for its own variable and only inside it" do
      flagged = scan_source(<<~RUBY).map { |h| "#{h[:receiver]}:#{h[:line]}" }
        instance = ::System::NodeInstance.find_or_create_by!(account: a, name: n) do |i|
          i.config = { "storage_volume" => {} }
          other.config = { "k" => 1 }
        end
        instance.config["k"] = 2
      RUBY

      expect(flagged).to contain_exactly("other:3", "instance:5")
    end

    it "skips a creation block whose `do |x|` sits on the closing-paren line" do
      expect(scan_source(<<~RUBY)).to be_empty
        instance = ::System::NodeInstance.find_or_create_by!(
          account: account, name: "x"
        ) do |i|
          i.config = { "storage_volume" => {} }
        end
      RUBY
    end

    it "does not treat an ordinary multi-line block as a creation block" do
      expect(scan_source(<<~RUBY).map { |h| h[:receiver] }).to eq([ "i" ])
        results.each_slice(
          10
        ) do |i|
          i.config = { "k" => 1 }
        end
      RUBY
    end

    it "reads the real tree, not an empty one" do
      expect(hits).not_to be_empty
      expect(keys).to include("app/models/concerns/system/config_document.rb#self")
    end
  end
end
