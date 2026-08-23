# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# IMP-915b24d21f4f — ONE builder for the WireGuard [Peer] field-set.
#
# WHY A DETECTOR AND NOT JUST "output unchanged". A refactor spec that pins
# rendered bytes proves the consolidation was faithful; it does NOT prove the
# duplication is gone, and it would stay green while a future field was added
# to one consumer only. That is exactly how this cost was realized twice
# already: WireGuard's mandatory PublicKey line was present in
# build_peer_entry from the start and absent from WgConfigRenderer's render
# loop until IMP-651ec6336654, and an AllowedIPs enrichment divergence between
# the renderer and HubAndSpoke#spoke_view is live today (offer
# 019ffee4-8a76-7196-9d00-1648f37d23f7).
#
# So this file guards the SEAM, from two directions:
#
#   1. A SOURCE RATCHET. No file under the extension's app/ tree may construct
#      a [Peer] field-set of its own — neither as a hash (the agent-facing
#      shape) nor as WireGuard INI text (the operator-facing shape). Both
#      spellings are checked, because the duplication spanned both.
#   2. A BEHAVIOURAL PROBE that ranges over all three call sites at once: a
#      field added at the builder must reach HubAndSpoke, FullMesh AND
#      WgConfigRenderer. A consumer that fabricates its own entry cannot see
#      the new field and reddens here.
#
# The ratchet is guarded against matching nothing: the same patterns, run
# against peer_entry.rb, must MATCH BOTH its literals, and each discriminator
# arm is exercised alone against a synthesized file rather than trusted by
# inspection (feeding two shapes to one example let a dead arm hide behind a
# live one — that is exactly how the "[Peer]" pattern shipped broken once).
#
# WHAT THIS GUARD DOES NOT COVER — read before trusting a green run:
#   - Scan scope is extensions/system/server/app/**/*.rb. server/lib/,
#     db/seeds/ and the CORE server/app tree are invisible to it.
#   - The INI pattern requires a double quote immediately before the token, so
#     a heredoc, a single-quoted string or %q() evades it.
#   - The hash pattern matches SYMBOL keys at line start. String keys
#     ("public_key" =>), incremental construction (entry[:public_key] = ...)
#     and .merge are invisible, as is any entry literal whose public_key: and
#     allowed_ips: are more than `hash_window` code lines apart.
#   - The behavioural probe wraps PeerEntry.build only. A consumer reverting to
#     a hand-rolled USER_DEVICE literal is caught by the source ratchet alone.
RSpec.describe "Sdwan::PeerEntry is the single [Peer] field-set builder" do
  # ---- the scan -------------------------------------------------------

  # Hash-shape construction: an entry is identified by `public_key:` and
  # `allowed_ips:` as hash keys in the same literal. That pair names a
  # WireGuard peer entry and nothing else in this tree — TopologyCompiler's
  # INTERFACE block carries `public_key:` (the peer's OWN key) with no
  # allowed_ips, and is correctly not an offender.
  # (Methods, not constants: constants assigned inside a describe block land
  # on Object and clobber any same-named constant in another spec file.)
  def hash_open_regex  = /^\s*public_key:\s/
  def hash_close_regex = /^\s*allowed_ips:\s/
  # How many code lines may separate the two keys of one entry literal.
  def hash_window = 20

  # INI-shape construction: a string literal that starts a WireGuard [Peer]
  # section or one of its field lines.
  # The \b binds to the WORD-shaped tokens only. Spelled as one trailing \b on
  # the whole alternation it silently killed the "[Peer]" arm — after "]" the
  # next char is a quote, so there is no word boundary there, and a consumer
  # emitting the section header with its field lines in any non-"-prefixed form
  # (heredoc, %q, single quotes) walked straight past the ratchet.
  def ini_regex = /"\s*(?:\[Peer\]|(?:PublicKey|Endpoint|AllowedIPs|PersistentKeepalive)\b)/

  # The files allowed to match either shape. An array from the start: the first
  # legitimate exception should cost one line, not a structural edit.
  def builder_relpath = "server/app/services/sdwan/peer_entry.rb"

  def allowed_relpaths = [ builder_relpath ]

  def extension_root
    Pathname.new(File.expand_path("../../..", __dir__))
  end

  def app_root
    extension_root.join("server", "app")
  end

  # Full-line comments only. The prose in these files quotes "[Peer]" and
  # names the entry keys constantly; the code does not.
  def code_lines(path)
    File.readlines(path, chomp: true).map { |l| l.strip.start_with?("#") ? "" : l }
  end

  def hash_offenders_in(path)
    lines = code_lines(path)
    lines.each_index.filter_map do |i|
      next unless lines[i].match?(hash_open_regex)

      window = lines[(i + 1)..(i + hash_window)] || []
      next unless window.any? { |l| l.match?(hash_close_regex) }

      { path: path, line: i + 1, shape: "hash", source: lines[i].strip }
    end
  end

  def ini_offenders_in(path)
    lines = code_lines(path)
    lines.each_index.filter_map do |i|
      next unless lines[i].match?(ini_regex)

      { path: path, line: i + 1, shape: "ini", source: lines[i].strip }
    end
  end

  def offenders_in(path)
    hash_offenders_in(path) + ini_offenders_in(path)
  end

  def scanned_files
    Dir.glob(app_root.join("**", "*.rb")).sort
  end

  def relpath(path)
    Pathname.new(path).relative_path_from(extension_root).to_s
  end

  def all_offenders
    scanned_files.reject { |p| allowed_relpaths.include?(relpath(p)) }.flat_map { |p| offenders_in(p) }
  end

  # ---- vacuity guards -------------------------------------------------

  it "resolves the app tree it claims to scan, and the three known consumers are in it" do
    files = scanned_files.map { |p| relpath(p) }

    expect(files.size).to be > 100
    expect(files).to include("server/app/services/sdwan/wg_config_renderer.rb")
    expect(files).to include("server/app/services/sdwan/topology_strategies/hub_and_spoke.rb")
    expect(files).to include("server/app/services/sdwan/topology_strategies/full_mesh.rb")
    expect(files).to include(builder_relpath)
  end

  it "matches the builder itself — a scan that finds nothing anywhere is not a guard" do
    builder = extension_root.join(builder_relpath).to_s

    # BOTH literals, not "at least one": `build` and `user_device` sit at
    # different key distances, so a window that had narrowed past `build` would
    # still be covered by `user_device` and the guard would read green while the
    # ratchet had quietly stopped catching full-size entries.
    expect(hash_offenders_in(builder).length).to be >= 2,
                                                 "the hash-shape pattern no longer matches BOTH Sdwan::PeerEntry.build " \
                                                 "and .user_device; it would now pass longer consumer literals vacuously"
    expect(ini_offenders_in(builder)).not_to be_empty,
                                             "the INI-shape pattern no longer matches Sdwan::PeerEntry#to_ini; " \
                                             "it would now pass every consumer vacuously"
  end

  describe "the discriminator, on synthesized files" do
    def offenders_for(body)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "probe.rb")
        File.write(path, body)
        offenders_in(path)
      end
    end

    it "flags a hand-rolled entry hash" do
      expect(offenders_for(<<~RUBY)).not_to be_empty
        {
          peer_id: peer.id,
          public_key: key.public_key,
          endpoint: nil,
          allowed_ips: allowed,
          persistent_keepalive: 25
        }
      RUBY
    end

    # One arm per example. Fed together, the PublicKey arm masked the fact that
    # the [Peer] arm matched nothing at all.
    it "flags a hand-rolled [Peer] section header on its own" do
      expect(offenders_for(%(out.puts "[Peer]"\n))).not_to be_empty
    end

    it "flags a hand-rolled WireGuard INI field line on its own" do
      expect(offenders_for(%(out.puts "PublicKey  = " + key.public_key\n))).not_to be_empty
    end

    it "does not flag an interface block that carries public_key with no allowed_ips" do
      expect(offenders_for(<<~RUBY)).to be_empty
        {
          name: interface_name(peer),
          address: peer.assigned_address,
          public_key: key&.public_key,
          vrf_name: vrf_name_for(peer)
        }
      RUBY
    end

    it "does not flag prose that quotes the field names" do
      expect(offenders_for(<<~RUBY)).to be_empty
        # the literal "[Peer]" token is also the section delimiter, and
        # "PublicKey  = ..." is what the builder emits.
        entry = ::Sdwan::PeerEntry.build(peer: peer, key: key, allowed_ips: allowed, keepalive: 25)
      RUBY
    end
  end

  # ---- the ratchet ----------------------------------------------------

  it "has no consumer constructing a [Peer] field-set of its own" do
    offenders = all_offenders.map { |o| "#{relpath(o[:path])}:#{o[:line]} (#{o[:shape]}) — #{o[:source]}" }

    expect(offenders).to be_empty, <<~MSG
      A [Peer] field-set is being built outside Sdwan::PeerEntry. This is the
      duplication IMP-915b24d21f4f removed, and it has cost twice already:
      WireGuard's mandatory PublicKey line was missing from the rendered config
      for as long as the renderer had its own copy. Route the site through
      Sdwan::PeerEntry.build (agent-facing hash) or .to_ini (operator-facing
      config text) instead.

      #{offenders.join("\n")}
    MSG
  end

  # ---- the behavioural probe, over all three call sites ---------------

  describe "a field added at the builder reaches every consumer" do
    let(:account) { Account.first || create(:account) }

    before { Sdwan::Network.where(account_id: account.id).delete_all }

    let!(:node) { create(:system_node, account: account, name: "pe-node-#{SecureRandom.hex(4)}") }
    let!(:instance_a) { create(:system_node_instance, node: node, name: "pe-a-#{SecureRandom.hex(2)}") }
    let!(:instance_b) { create(:system_node_instance, node: node, name: "pe-b-#{SecureRandom.hex(2)}") }

    def enroll_hub(network, instance)
      Sdwan::PeerEnroller.call(network: network, node_instance: instance,
                               publicly_reachable: true, endpoint_host: "203.0.113.10",
                               endpoint_port: 51_820)
    end

    # The probe: every entry the builder hands back gains a marker key. A
    # consumer that fabricates its own entry never sees it.
    before do
      allow(Sdwan::PeerEntry).to receive(:build).and_wrap_original do |orig, **kwargs|
        orig.call(**kwargs).merge(zz_probe_field: "PROBE")
      end
    end

    it "reaches HubAndSpoke#peers_for" do
      network = Sdwan::Network.create!(account_id: account.id, name: "hs-#{SecureRandom.hex(4)}")
      hub = enroll_hub(network, instance_a)
      spoke = Sdwan::PeerEnroller.call(network: network, node_instance: instance_b)

      view = described_strategy(Sdwan::TopologyStrategies::HubAndSpoke, network).peers_for(spoke.reload)

      entry = view.find { |e| e[:peer_id] == hub.id }
      expect(entry).to be_present
      expect(entry[:zz_probe_field]).to eq("PROBE"),
                                        "HubAndSpoke built its own entry instead of using Sdwan::PeerEntry.build"
    end

    it "reaches FullMesh#peers_for" do
      network = Sdwan::Network.create!(account_id: account.id, name: "fm-#{SecureRandom.hex(4)}",
                                       settings: { "topology_strategy" => "full_mesh" })
      peer_a = enroll_hub(network, instance_a)
      peer_b = Sdwan::PeerEnroller.call(network: network, node_instance: instance_b)

      view = described_strategy(Sdwan::TopologyStrategies::FullMesh, network).peers_for(peer_a.reload)

      entry = view.find { |e| e[:peer_id] == peer_b.id }
      expect(entry).to be_present
      expect(entry[:zz_probe_field]).to eq("PROBE"),
                                        "FullMesh built its own entry instead of using Sdwan::PeerEntry.build"
    end

    it "reaches WgConfigRenderer, whose rendered section is the builder's entry verbatim" do
      network = Sdwan::Network.create!(account_id: account.id, name: "wg-#{SecureRandom.hex(4)}")
      enroll_hub(network, instance_a)

      grant = create(:sdwan_access_grant, account: account, network: network.reload)
      device = create(:sdwan_user_device, access_grant: grant)
      allow(device).to receive(:private_key_b64).and_return("FAKE-TEST-PLACEHOLDER")

      rendered_sections = []
      allow(Sdwan::PeerEntry).to receive(:to_ini).and_wrap_original do |orig, entry, **kwargs|
        orig.call(entry, **kwargs).tap { |section| rendered_sections << [ entry, section ] }
      end

      text = Sdwan::WgConfigRenderer.render(device)

      expect(rendered_sections.length).to eq(1)
      entry, section = rendered_sections.first
      expect(entry[:zz_probe_field]).to eq("PROBE"),
                                        "WgConfigRenderer built its own entry instead of using Sdwan::PeerEntry.build"
      # The section is emitted verbatim — the renderer adds no [Peer] field of
      # its own on top of the builder's output.
      expect(text).to include(section)
      expect(text.scan("[Peer]").length).to eq(1)
    end

    def described_strategy(klass, network)
      klass.new(network: network.reload)
    end
  end
end
