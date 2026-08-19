# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("../extensions/system/server/db/seeds/_smoke_k3s_helpers").to_s

# IMP-de7b0ec66dea — Phase 5 of the K3s lifecycle smoke drove all three
# Sdwan::Executors::*FederationPeer classes through a constructor they have
# never had (`account:`/`user:`/`agent:`/`params:`/`confirmed:`), while
# System::Executors::Base takes `(params, deferred_operation:)`. The script
# therefore raised ArgumentError at its first executor call and the smoke
# catalog counted coverage it did not deliver.
#
# The seed is a straight-line script, so this runs it — nothing about the
# federation legs is re-implemented here. Only the host-dependent parts are
# stubbed (tier gate, the 8-item preflight, the /tmp state sidecar, and the
# cross-site kubectl leg, which needs a live Site B and a kubectl binary).
# Everything from "Propose federation peer" down executes for real against
# the test DB, which is what makes this red on the stale constructor.
RSpec.describe "smoke_test_k3s_federation seed (IMP-de7b0ec66dea)" do
  let(:seed_path) do
    Rails.root.join("../extensions/system/server/db/seeds/smoke_test_k3s_federation.rb").to_s
  end
  let(:helpers) { ::System::Seeds::SmokeK3sHelpers }

  let(:account)   { create(:account) }
  let!(:operator) { create(:user, account: account) }
  let(:a_cluster) { create(:devops_kubernetes_cluster, account: account) }
  let(:b_cluster) { create(:devops_kubernetes_cluster, account: account) }
  let(:a_network) { create(:sdwan_network, account: account) }
  let(:b_network) { create(:sdwan_network, account: account) }

  let(:sidecar) do
    {
      "site_a_cluster_id" => a_cluster.id,
      "site_b_cluster_id" => b_cluster.id,
      "site_a_network_id" => a_network.id,
      "site_b_network_id" => b_network.id
    }
  end

  # IMP-0ca5fbe5c532 — the spec supplies the destination, so nothing about this
  # run depends on what is or is not already sitting in the shared /tmp.
  let(:kubeconfig_dir) { Dir.mktmpdir("federation-smoke-spec-") }

  around do |example|
    saved = ENV["SMOKE_K3S_KUBECONFIG_DIR"]
    ENV["SMOKE_K3S_KUBECONFIG_DIR"] = kubeconfig_dir
    example.run
  ensure
    ENV["SMOKE_K3S_KUBECONFIG_DIR"] = saved
    FileUtils.remove_entry(kubeconfig_dir) if Dir.exist?(kubeconfig_dir)
  end

  before do
    allow(helpers).to receive(:current_tier).and_return("full")
    allow(helpers).to receive(:tier_gate).and_return("full")
    allow(helpers).to receive(:preflight!)
    allow(helpers).to receive(:discover_or_create_account!).and_return(account)
    allow(helpers).to receive(:state_read).and_return(sidecar)
    allow(helpers).to receive(:state_write)

    # The cross-site API-plane leg used to be skipped here by stubbing
    # tier_at_least?("site") false — impossible in a real run, since the phase
    # gates at full (IMP-c75106b72ef8 deleted that guard). The leg now always
    # runs, so it is neutered at its three host-dependent seams instead: a
    # kubeconfig fetch that would call the provisioning tool against a live
    # Site B, and a kubectl that would need a binary and a route to it.
    # /bin/false stands in for the binary: it exits non-zero without a network,
    # so the leg deterministically takes its soft-fail path.
    allow(helpers).to receive(:kubectl_available?).and_return(true)
    allow(helpers).to receive(:fetch_kubeconfig!)
    allow(helpers).to receive(:kubectl_binary).and_return("/bin/false")

    # #fail_with aborts the process, which RSpec deliberately does not rescue
    # (SystemExit is in AVOID_RESCUING). Re-raise as a StandardError so a
    # failed h.assert surfaces as a spec failure instead of killing the run.
    allow(helpers).to receive(:fail_with) { |msg| raise "SMOKE FAIL: #{msg}" }
  end

  def peer
    ::System::FederationPeer.where(account: account).sole
  end

  # IMP-0ca5fbe5c532 — ISOLATION MUST BE STRUCTURAL, NOT ONE STUB DEEP.
  #
  # The seed used to write Site B's kubeconfig to a fixed
  # /tmp/k3s-smoke-kubeconfig-b. On a host that has ever run a real smoke that
  # file EXISTS and holds a live cluster's credentials, so the single
  # `fetch_kubeconfig!` stub in the before block was the only thing standing
  # between this suite and them — and between a spec run and OVERWRITING them.
  # Same defect class as the agent tests that mutated a live /persist: a
  # constant path bypasses every test seam, because a seam only helps where
  # someone remembered to install one.
  #
  # The stub above stays as layered defense. This asserts the layer underneath
  # it: even unstubbed, the destination is per-run and injectable.
  describe "kubeconfig destination" do
    it "fetches into the caller-supplied directory, never the legacy shared path" do
      captured = nil
      allow(helpers).to receive(:fetch_kubeconfig!) { |**kw| captured = kw[:dest_path] }

      load seed_path

      expect(captured).to be_present, "the cross-site API leg never fetched a kubeconfig"
      expect(File.dirname(captured)).to eq(kubeconfig_dir)
      expect(captured).not_to eq("/tmp/k3s-smoke-kubeconfig-b"),
                              "a live cluster's kubeconfig is one unstubbed call away"
    end

    # With no override the default must still be ephemeral — the override is a
    # convenience for operators who want a stable path, not the thing that
    # makes this safe.
    # With no override the default must still be ephemeral. Asserted as the
    # PROPERTY (two runs never share a directory), not as a string prefix —
    # mktmpdir keeps the readable "k3s-smoke-kubeconfig-" prefix on purpose, so
    # an operator can still find it with `ls -d /tmp/k3s-smoke-kubeconfig-*`,
    # and a prefix assertion would have failed a perfectly safe path.
    it "defaults to a fresh private tmpdir rather than a predictable name" do
      ENV.delete("SMOKE_K3S_KUBECONFIG_DIR")

      first = helpers.kubeconfig_dest("b")
      helpers.reset_kubeconfig_dir!
      second = helpers.kubeconfig_dest("b")

      expect(first).not_to eq("/tmp/k3s-smoke-kubeconfig-b"), "still the legacy fixed path"
      expect(File.dirname(first)).not_to eq(File.dirname(second)),
                                         "two runs shared a directory — collisions are back"
      # 0700: fetch_kubeconfig! writes with a bare File.write, so the DIRECTORY
      # is what keeps another local user off a live cluster's credentials.
      expect(File.stat(File.dirname(first)).mode & 0o777).to eq(0o700)
    ensure
      [ first, second ].compact.each do |path|
        FileUtils.remove_entry(File.dirname(path)) if path && Dir.exist?(File.dirname(path))
      end
      helpers.reset_kubeconfig_dir!
    end
  end

  it "proposes and accepts a federation peer through the executor contract" do
    expect { load seed_path }.not_to raise_error

    expect(peer.status).to eq("accepted")
    expect(peer.remote_instance_url).to eq("https://powernode-site-b.smoke.local")
    expect(peer.spawn_mode).to eq("autonomous_peer")
  end

  # The account the peer is created under comes from the executor's
  # `deferred_operation&.account`, so a context that does not carry it would
  # fail FederationPeer's `belongs_to :account` rather than land elsewhere.
  it "creates the peer under the smoke's account" do
    load seed_path

    expect(peer.account_id).to eq(account.id)
  end

  # ProposeFederationPeer mints an acceptance token by default, and accept!
  # refuses a peer carrying a digest unless the plaintext is presented. The
  # smoke has to carry the minted token from propose into accept; if it does
  # not, AcceptFederationPeer raises (e655659f made that refusal loud).
  it "threads the minted single-use acceptance token into the accept leg" do
    load seed_path

    expect(peer.metadata["acceptance_token_used"]).to be(true)
    expect(peer.acceptance_token_digest).to be_nil
    expect(peer.acceptance_token_expires_at).to be_nil
  end

  # accept! stamps the accepting operator from `deferred_operation&.requested_by`,
  # never from params — so this pins that the smoke's context carries a user.
  it "records the accepting operator on the peer" do
    load seed_path

    expect(peer.metadata["accepted_by_user_id"]).to eq(operator.id)
  end

  context "with the optional revoke pass enabled" do
    around do |example|
      previous = ENV["SMOKE_K3S_FEDERATION_REVOKE"]
      ENV["SMOKE_K3S_FEDERATION_REVOKE"] = "1"
      example.run
    ensure
      ENV["SMOKE_K3S_FEDERATION_REVOKE"] = previous
    end

    it "revokes the peer with an audited reason" do
      expect { load seed_path }.not_to raise_error

      expect(peer.status).to eq("revoked")
      expect(peer.metadata["revocation_reason"]).to be_present
    end
  end
end

# IMP-c75106b72ef8 — the seed gates the whole phase at `full`, but its header
# tier table advertised propose/accept from "site+" up, and it wrapped the
# cross-site API-plane leg in `if h.tier_at_least?("site")` — a condition that
# cannot be false once the full-tier gate has passed. Gate and prose disagreed
# about which tiers get federation coverage; the gate is authoritative.
#
# Both halves are source-level properties — a branch with no reachable false arm,
# and prose that contradicts the gate above it — so the oracle reads the seed and
# the catalog instead of running them. The gate tier is parsed OUT of the seed
# rather than hardcoded, so if the gate is ever lowered deliberately the check
# relaxes with it instead of pinning today's answer.
#
# Deliberately scoped to this one seed. Of the nine smoke_test_k3s_*.rb, seven
# gate at "db" and smoke_test_k3s_runtime.rb has no tier_gate at all, so every
# tier_at_least?("single"/"site") guard outside this file sits above (or without)
# its gate and keeps a reachable false arm. This one was the only dead guard.
RSpec.describe "smoke_test_k3s_federation tier gate vs. documentation (IMP-c75106b72ef8)" do
  let(:seed_source) do
    File.read(Rails.root.join("../extensions/system/server/db/seeds/smoke_test_k3s_federation.rb"))
  end
  let(:catalog_source) do
    File.read(Rails.root.join("../extensions/system/docs/SMOKE_TEST.md"))
  end

  let(:tier_index) { ::System::Seeds::SmokeK3sHelpers::TIER_INDEX }
  let(:gate_tier)  { seed_source[/h\.tier_gate\(required: "(\w+)"\)/, 1] }
  let(:gate_rank)  { tier_index.fetch(gate_tier) }

  it "gates the phase at a tier the helper actually knows" do
    expect(gate_tier).to be_present, "no h.tier_gate(required: ...) found in the seed"
    expect(tier_index).to have_key(gate_tier)
  end

  it "has no tier_at_least? guard that the gate already guarantees" do
    dead = seed_source.scan(/h\.tier_at_least\?\(["'](\w+)["']\)/).flatten
                      .select { |tier| tier_index.fetch(tier) <= gate_rank }

    expect(dead).to be_empty,
                    "dead tier guard(s) #{dead.inspect}: tier_gate(required: #{gate_tier.inspect}) " \
                    "has already returned by then, so tier_at_least? can never be false there"
  end

  # The header's tier table is the run of `#   <tiers>: <description>` rows
  # directly under the "Tier semantics:" line, ending at the first bare "#".
  # Any tier ranked BELOW the gate is skipped by the gate itself, so its row must
  # say so — a row promising work at such a tier is prose the script cannot
  # honour. The character class is [ \t] rather than \s on purpose: \s matches
  # newlines, which would let the run swallow the bare "#" separator and keep
  # going through the whole header comment, scanning prose that is not the table
  # (the "cross-site API plane" line below it reads as a "site" claim).
  it "documents every sub-gate tier as skipped in the header tier table" do
    table = seed_source[/^# Tier semantics:\n((?:#[ \t]+\S.*\n)+)/, 1].to_s
    rows = table.lines.filter_map do |line|
      match = line.match(/^#\s+(?<tiers>[^:]+):\s*(?<description>.+)$/)
      match && [ match[:tiers], match[:description] ]
    end

    expect(rows).not_to be_empty, "could not parse the header 'Tier semantics:' table"

    overclaimed = rows.reject { |_tiers, description| description.match?(/skipped/i) }
                      .flat_map { |tiers, _description| tiers.scan(/db|single|site|full/) }
                      .select { |tier| tier_index.fetch(tier) < gate_rank }

    expect(overclaimed).to be_empty,
                           "header promises work at #{overclaimed.inspect}, but the phase gates at " \
                           "#{gate_tier.inspect} and exits 0 below it"
  end

  # Same disagreement, restated one file over. The catalog's convention for a
  # tier claim is a bare or parenthesised tier token, usually suffixed "+"
  # ("(site+)", "site+ (db tier: synth)"). The lookbehind matters: "cross-site"
  # ends in a legitimate, non-tier "site" that must not read as a claim, and the
  # scan is case-sensitive so the prose "Site A ↔ Site B" does not either.
  it "does not advertise sub-gate tier coverage in the smoke catalog row" do
    row = catalog_source.lines.find do |line|
      line.start_with?("|") && line.include?("`smoke_test_k3s_federation.rb`")
    end
    expect(row).to be_present, "no smoke_test_k3s_federation.rb row in docs/SMOKE_TEST.md"

    # Guards the vacuity path: if the table ever gains or loses a column, [4]
    # would silently be nil and every scan below would find nothing to object to.
    description = row.split("|").map(&:strip)[4].to_s
    expect(description).not_to be_empty, "catalog row has no description column: #{row.inspect}"

    overclaimed = description.scan(/(?<![\w-])(db|single|site|full)\+?(?=\)|\s|\z)/).flatten
                             .select { |tier| tier_index.fetch(tier) < gate_rank }

    expect(overclaimed).to be_empty,
                           "catalog row claims #{overclaimed.inspect} coverage for a phase gated at " \
                           "#{gate_tier.inspect}: #{description.inspect}"
  end

  # The description above is prose; THIS column is the catalog's authoritative
  # statement of the gate ("site+ (db tier: synth)" on the sibling rows), so it
  # is the cell that has to agree with tier_gate. Checked separately because a
  # sub-gate tier here is not an overclaim in the description's sense — it is
  # the catalog naming the wrong gate outright.
  it "names the seed's gate tier in the catalog's tier column" do
    row = catalog_source.lines.find do |line|
      line.start_with?("|") && line.include?("`smoke_test_k3s_federation.rb`")
    end
    expect(row).to be_present, "no smoke_test_k3s_federation.rb row in docs/SMOKE_TEST.md"

    tier_cell = row.split("|").map(&:strip)[5].to_s
    expect(tier_cell).not_to be_empty, "catalog row has no tier column: #{row.inspect}"

    declared = tier_cell[/\A(db|single|site|full)\+?/, 1]

    expect(declared).to eq(gate_tier),
                        "catalog tier column #{tier_cell.inspect} declares #{declared.inspect}, " \
                        "but the seed gates at #{gate_tier.inspect}"
  end
end
