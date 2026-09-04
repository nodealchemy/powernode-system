# frozen_string_literal: true

require "spec_helper"
require "find"

# IMP-01b1e152f667 — extension isolation (gate #9). The public, MIT-licensed
# system extension must not name the private billing extension's `Billing::`
# namespace anywhere in its tree: cross-extension traffic goes through core's
# generic Powernode::BillingBridge seam (check_provisioning_quota /
# record_provisioning_event).
#
# IMP-cf4f8bcd02c3 widened the scan from server/app to the WHOLE extension
# tree. Scoped to server/app, the ratchet could not see a spec that still
# stubbed ::Billing::ProvisioningQuotaGuard under a `defined?` guard and passed
# only transitively through the registered handler. A spec is as much a
# dependency as the code it exercises, and it ships in the same public clone,
# so it is held to the same property: stub the seam, never the private class.
#
# The core-purity hook does not enforce model namespaces (its header records
# why), so this file is the ratchet. Rails-free, byte-oriented file scan. The
# acceptance property is a raw `grep -rn "::Billing::" extensions/system`, so
# comments count too — a comment is how the last stale copy of a claim
# survives — and so does every file type, not just *.rb: an .erb view, a .rake
# task, a .yml default or a doc names a constant just as effectively. Scan is
# byte-oriented for that reason (a non-UTF-8 asset must not raise here).
#
# The scanned set is what the extension PUBLISHES, taken from git itself:
# `git ls-files -co --exclude-standard` = tracked files plus untracked ones that
# .gitignore does not exclude. A hand-maintained prune list was tried first and
# matched .gitignore in neither direction — it still scanned gitignored local
# output (so a purely local file could fail a published-purity gate) while
# skipping tracked paths whose basename collided with it (`log`, `tmp` and
# `build` all occur inside modules/*/rootfs). Untracked-but-not-ignored files
# are included deliberately: a brand-new spec must not get a free pass until it
# is committed. The Find walk survives only as the fallback for a checkout with
# no usable git (an exported tarball), where "published" cannot be derived.
#
# Exactly two files are excluded, each for a stated reason:
#   * this file — it must spell the token it forbids;
#   * server/spec/integration/enterprise_smoke_spec.rb — an integration smoke
#     of the paid tier that legitimately SKIPS unless Billing::Plan is loaded
#     and then drives the private extension's services directly. There is no
#     seam to route it through: exercising the private extension IS its job.
#     The second example pins that the exemption is still earned, so the
#     exemption cannot outlive the skip guard that justifies it.
RSpec.describe "extensions/system billing-namespace purity" do
  extension_root = File.expand_path("../../..", __dir__)
  smoke_spec = "server/spec/integration/enterprise_smoke_spec.rb"
  self_spec = "server/spec/lint/billing_namespace_seam_spec.rb"
  # Exemptions are matched on the path RELATIVE to extension_root, so a
  # checkout reached through a symlink (where __FILE__ and a realpath-resolved
  # root disagree) cannot silently stop matching and fail this file on its own
  # text.
  exempt = [ self_spec, smoke_spec ].freeze

  # Fallback only (no git): directories that never hold publishable source.
  pruned_dirs = %w[.git node_modules .bundle .claude coverage tmp log dist build].freeze

  published_files = lambda do
    out = begin
      IO.popen(
        [ "git", "-C", extension_root, "ls-files", "-co", "--exclude-standard", "-z" ],
        err: File::NULL, &:read
      )
    rescue StandardError
      nil
    end
    return nil unless out && $?&.success?

    out.split("\0").reject(&:empty?).uniq
  end

  walked_files = lambda do
    files = []
    Find.find(extension_root) do |path|
      if File.directory?(path)
        Find.prune if path != extension_root && pruned_dirs.include?(File.basename(path))
        next
      end
      files << path.delete_prefix("#{extension_root}/")
    end
    files
  end

  scan_files = lambda do
    (published_files.call || walked_files.call)
      .reject { |rel| exempt.include?(rel) }
      .select { |rel| File.file?(File.join(extension_root, rel)) }
      .sort
  end

  it "names no Billing:: constant anywhere in the extension tree (routes through Powernode::BillingBridge)" do
    hits = scan_files.call.flat_map do |rel|
      File.read(File.join(extension_root, rel), mode: "rb").force_encoding(Encoding::BINARY)
          .split("\n", -1).each_with_index.filter_map do |line, index|
        next unless line.match?(/\bBilling::\w+/)

        # The line is BINARY; the message is UTF-8. Scrub so a hit is REPORTED
        # rather than turned into an Encoding::CompatibilityError.
        "#{rel}:#{index + 1}: #{line.strip.force_encoding(Encoding::UTF_8).scrub("?")}"
      end
    end

    expect(hits).to be_empty,
      "extensions/system must not reference the private Billing:: namespace — " \
      "route through Powernode::BillingBridge (stub it in specs) instead. Found:\n  #{hits.join("\n  ")}"
  end

  it "scans this file's own directory, so the exemption list cannot silently cover the tree" do
    scanned = scan_files.call

    expect(scanned).to include("server/spec/services/ai/tools/system_fleet_tool_provision_contract_spec.rb"),
      "the published-file scan returned #{scanned.size} files but not the spec this ratchet was widened " \
      "to reach; `git ls-files -co --exclude-standard` in #{extension_root} is not returning the tree"
    expect(scanned).not_to include(*exempt)
  end

  it "keeps the enterprise smoke exemption earned: it skips unless Billing::Plan is loaded" do
    source = File.read(File.join(extension_root, smoke_spec), mode: "rb").force_encoding(Encoding::BINARY)

    expect(source).to match(/^\s*skip\b.*\bunless\b.*defined\?\(::Billing::Plan\)/),
      "#{smoke_spec} is exempt from the Billing:: scan ONLY because it skips itself whenever " \
      "the private extension is absent; that guard is gone, so the exemption is no longer earned"
  end
end
