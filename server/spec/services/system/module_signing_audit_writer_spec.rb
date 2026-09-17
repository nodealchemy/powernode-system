# frozen_string_literal: true

require "rails_helper"

# IMP-c52b5c2d6cbf — ingest for the module-signing ladder's AUDIT findings.
#
# The audit rungs exist to measure what an enforcing rung would refuse. Until
# this writer, every finding went to the node's stderr — the service journal, or
# the initramfs console for the boot composer — so "run audit until the fleet is
# quiet" meant reading every node's journal by hand, and the ladder's default
# stayed `off` because nobody could see fleet-wide whether enforcing was safe.
#
# The agent now reports a BLOCK on the heartbeat (agent/internal/signingaudit):
# a findings list plus a truncation flag. This class records it, keeping the
# three absences apart the way System::RuntimeMetricsWriter does: no block at
# all (audit never ran here), a block whose list is empty (audit ran, node is
# QUIET — the fact the whole ladder waits for), and real findings.
RSpec.describe System::ModuleSigningAuditWriter do
  let(:account)  { create(:account) }
  let(:template) { create(:system_node_template, account: account) }
  let(:node)     { create(:system_node, account: account, node_template: template) }
  let(:instance) { create(:system_node_instance, node: node, status: "running") }

  def finding(stage: "verify:module_signature_audit", detail: "would refuse /persist/blobs/aa: no cosign bundle",
              count: 1, first_seen: "2026-09-17T10:00:00Z", last_seen: "2026-09-17T10:05:00Z")
    { "stage" => stage, "detail" => detail, "count" => count,
      "first_seen" => first_seen, "last_seen" => last_seen }
  end

  def block(findings, truncated: false, mode: "audit")
    { "findings" => findings, "truncated" => truncated, "mode" => mode }
  end

  def document
    instance.reload.config["module_signing_audit"]
  end

  describe "the three absences" do
    it "writes nothing when the heartbeat carried no block (audit never ran here)" do
      expect(described_class.write!(instance: instance, payload: nil)).to be_nil
      expect(document).to be_nil
    end

    # Distinct from the above and from a finding: the agent measured and had
    # nothing to report. Enforcing is justified by the ABSENCE of findings, so
    # this is the fact the ladder waits for — a reader must be able to tell
    # "quiet" from "unknown" or the measurement is worthless.
    it "records an empty findings list as a measurement with no findings" do
      # Aged so a stamp copied off the row (rather than taken now) fails below.
      instance.update_column(:created_at, 3.days.ago)

      described_class.write!(instance: instance, payload: block([]))

      expect(document).to include("findings" => [], "finding_count" => 0)
      # The runbook tells operators to gate on observed_at, because a node moved
      # back to `off` keeps its last document forever — a frozen or copied stamp
      # would let a stale document read as current, which is the one thing that
      # check exists to prevent.
      expect(Time.iso8601(document["observed_at"])).to be_within(30.seconds).of(Time.current)
    end

    it "records findings when the node reported them" do
      described_class.write!(instance: instance, payload: block([ finding ]))

      expect(document["finding_count"]).to eq(1)
      expect(document["findings"].first).to include("stage" => "verify:module_signature_audit")
    end
  end

  # A malformed block is NOT an empty measurement: recording it as one would
  # claim the node is quiet on the strength of a report the server cannot read,
  # which is the one lie that would matter here.
  describe "malformed blocks never read as QUIET" do
    [
      [ "a bare array (the pre-block wire shape)", [] ],
      [ "a string",                                 "quiet" ],
      [ "a block with no findings key",             { "truncated" => false } ],
      [ "a block whose findings are not a list",    { "findings" => "none" } ],
      [ "a block whose findings are a hash",        { "findings" => { "0" => "x" } } ]
    ].each do |label, payload|
      it "writes nothing for #{label}" do
        expect(described_class.write!(instance: instance, payload: payload)).to be_nil
        expect(document).to be_nil
      end
    end
  end

  describe "findings" do
    it "records the stage, detail and repeat count of each distinct finding" do
      described_class.write!(instance: instance, payload: block([
        finding,
        finding(stage: "verify:module_fsverity_audit", detail: "would refuse /persist/blobs/bb: no fsverity_root_hash published", count: 12)
      ]))

      expect(document["finding_count"]).to eq(2)
      expect(document["findings"].map { |f| f["stage"] })
        .to contain_exactly("verify:module_signature_audit", "verify:module_fsverity_audit")
      fsverity = document["findings"].find { |f| f["stage"] == "verify:module_fsverity_audit" }
      expect(fsverity["count"]).to eq(12)
      expect(fsverity["detail"]).to include("no fsverity_root_hash published")
      expect(fsverity["first_seen"]).to eq("2026-09-17T10:00:00Z")
    end

    # A non-enforcing site with no trust anchor degrades to no verification and
    # reports `verify:module_signing`. That node is configured for audit and is
    # verifying NOTHING — the row has to survive, or it reports finding_count 0
    # and reads as QUIET exactly when an operator is deciding to enforce.
    it "keeps the measurement's own failure modes, which prove a quiet reading worthless" do
      described_class.write!(instance: instance, payload: block([
        finding(stage: "verify:module_signing", detail: "module signing audit at service degraded to no verification"),
        finding(stage: "verify:module_signing_keys", detail: "refresh platform module-signing keys: connection refused")
      ]))

      expect(document["findings"].map { |f| f["stage"] })
        .to contain_exactly("verify:module_signing", "verify:module_signing_keys")
    end

    # The stage is what a reader gates on: which arm of the ladder is failing.
    # An unrecognized stage is a producer the server does not understand, and
    # storing it would put an unreadable row under a key an operator reads as
    # "signing audit".
    it "drops a finding whose stage is not a module-signing stage" do
      described_class.write!(instance: instance, payload: block([
        finding, finding(stage: "compose:identity_write", detail: "permission denied")
      ]))

      expect(document["findings"].map { |f| f["stage"] }).to eq([ "verify:module_signature_audit" ])
      expect(document["finding_count"]).to eq(1)
    end

    it "drops entries that are not findings at all rather than failing the ingest" do
      described_class.write!(instance: instance, payload: block([ nil, "x", [ finding ], finding ]))

      expect(document["finding_count"]).to eq(1)
    end

    it "reads symbol-keyed entries, as a Ruby-side caller would pass them" do
      described_class.write!(instance: instance, payload: {
        findings: [ { stage: "verify:module_signature_audit", detail: "would refuse /b/aa: no cosign bundle", count: 2 } ],
        truncated: false
      })

      expect(document["findings"].first).to include("stage" => "verify:module_signature_audit", "count" => 2)
    end
  end

  describe "bounds on an untrusted producer" do
    it "bounds the findings and the detail length a node can put on a read surface" do
      long = "would refuse /persist/blobs/aa: #{'x' * 2_000}"
      findings = [ finding(detail: long) ] + Array.new(described_class::MAX_FINDINGS + 5) do |i|
        finding(detail: "would refuse /persist/blobs/#{i}: no cosign bundle")
      end

      described_class.write!(instance: instance, payload: block(findings))

      expect(document["findings"].size).to eq(described_class::MAX_FINDINGS)
      # finding_count must count the rows actually stored. Reporting the
      # pre-cap total beside a capped list would overstate what the document
      # can show, in the one field a reader scans first.
      expect(document["finding_count"]).to eq(described_class::MAX_FINDINGS)
      expect(document["findings"].map { |f| f["detail"].length }.max)
        .to be <= described_class::MAX_DETAIL_CHARS
    end

    # The cap must not be reachable only by normalizing the whole payload first:
    # a node posting 200k entries every 30s would burn a request worker on rows
    # that are discarded. Stopping early is what keeps that bounded.
    it "stops normalizing once the cap is reached" do
      booby_trap = Class.new(Hash) do
        def [](_key)
          raise "the writer normalized an entry past its cap"
        end
      end.new
      findings = Array.new(described_class::MAX_FINDINGS + 1) do |i|
        finding(detail: "would refuse /persist/blobs/#{i}: no cosign bundle")
      end + Array.new(5_000) { booby_trap }

      described_class.write!(instance: instance, payload: block(findings))

      expect(document["findings"].size).to eq(described_class::MAX_FINDINGS)
    end

    it "keeps a non-numeric count out of the document rather than coercing it to a plausible 1" do
      described_class.write!(instance: instance, payload: block([ finding(count: "lots") ]))

      expect(document["findings"].first["count"]).to be_nil
    end

    # A repeat count is a cardinal: a negative one is not a count, and an
    # unbounded Integer is a node writing whatever it likes onto a read surface.
    it "rejects a negative or absurd count" do
      described_class.write!(instance: instance, payload: block([
        finding(detail: "would refuse /b/neg: x", count: -5),
        finding(detail: "would refuse /b/huge: x", count: 10**40)
      ]))

      expect(document["findings"].map { |f| f["count"] }).to eq([ nil, nil ])
    end

    it "records truncation the agent reported, so finding_count is not read as the node's whole problem" do
      described_class.write!(instance: instance, payload: block([ finding ], truncated: true))

      expect(document["truncated"]).to be(true)
    end

    it "records its own truncation when the node sent more than the server keeps" do
      findings = Array.new(described_class::MAX_FINDINGS + 1) do |i|
        finding(detail: "would refuse /persist/blobs/#{i}: no cosign bundle")
      end

      described_class.write!(instance: instance, payload: block(findings, truncated: false))

      expect(document["truncated"]).to be(true)
    end

    it "reports no truncation when nothing was dropped at either end" do
      described_class.write!(instance: instance, payload: block([ finding ]))

      expect(document["truncated"]).to be(false)
    end
  end

  # An empty findings list proves different things on different rungs: under
  # `audit` both arms ran, under `runtime`/`all` the signature arm enforces and
  # reports nothing, so "quiet" covers only fs-verity. Without the rung an
  # operator reads a runtime node as verified-clean and advances to `all` — the
  # rung that makes an unsigned module an unbootable node.
  describe "attribution" do
    it "records the rung the measurement came from" do
      described_class.write!(instance: instance, payload: block([], mode: "runtime"))

      expect(document["mode"]).to eq("runtime")
    end

    it "normalizes the rung the node reported" do
      described_class.write!(instance: instance, payload: block([], mode: " AUDIT "))

      expect(document["mode"]).to eq("audit")
    end

    # A measurement the server cannot attribute must not attribute itself by
    # default: nil is the honest answer, and a reader must not treat it as a pass.
    it "keeps an unrecognized rung out of the document rather than guessing" do
      described_class.write!(instance: instance, payload: block([], mode: "enforce"))

      expect(document["mode"]).to be_nil
      expect(document["finding_count"]).to eq(0)
    end

    it "records no rung when the node named none" do
      described_class.write!(instance: instance, payload: { "findings" => [] })

      expect(document["mode"]).to be_nil
    end
  end

  # Each qualifying heartbeat writes a FRESH snapshot: a finding the agent stops
  # reporting must disappear rather than linger as a stale positive, which is
  # the defect System::BootLkgStateWriter's frozen "armed" taught.
  it "replaces the previous document instead of merging onto it" do
    described_class.write!(instance: instance, payload: block([ finding(detail: "would refuse /persist/blobs/old: x") ]))
    described_class.write!(instance: instance, payload: block([ finding(detail: "would refuse /persist/blobs/new: x") ]))

    expect(document["findings"].map { |f| f["detail"] }).to eq([ "would refuse /persist/blobs/new: x" ])
  end

  # config is a shared jsonb document written by several writers in the same
  # request cycle; a read-modify-write here would erase a sibling's block.
  #
  # The sibling key is written STRAIGHT TO THE ROW, not through `instance`, so
  # the object the writer receives is deliberately stale. Writing it through
  # `instance` would leave the assertion passing against a read-modify-write
  # implementation — the in-memory config would still carry the sibling — and
  # so would test nothing.
  it "leaves a sibling writer's config key untouched even when its own object is stale" do
    System::NodeInstance.where(id: instance.id).update_all([
      "config = COALESCE(config, '{}'::jsonb) || ?::jsonb",
      { "runtime_metrics" => { "mount_state" => "mounted" } }.to_json
    ])
    expect(instance.config["runtime_metrics"]).to be_nil # the stale object the writer gets

    described_class.write!(instance: instance, payload: block([ finding ]))

    expect(instance.reload.config["runtime_metrics"]).to eq({ "mount_state" => "mounted" })
    expect(document["finding_count"]).to eq(1)
  end
end
