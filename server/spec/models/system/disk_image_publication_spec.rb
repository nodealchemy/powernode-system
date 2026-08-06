# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::DiskImagePublication, type: :model do
  let(:account) { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }

  describe "validations" do
    it "rejects malformed sha256" do
      pub = build(:system_disk_image_publication, account: account, node_platform: platform, sha256: "tooshort")
      expect(pub).not_to be_valid
      expect(pub.errors[:sha256]).to include("must be 64 hex chars")
    end

    it "requires a valid arch" do
      pub = build(:system_disk_image_publication, account: account, node_platform: platform, arch: "x86")
      expect(pub).not_to be_valid
    end

    it "rejects negative size_bytes" do
      pub = build(:system_disk_image_publication, account: account, node_platform: platform, size_bytes: -1)
      expect(pub).not_to be_valid
    end

    it "enforces unique git_sha within a platform" do
      first = create(:system_disk_image_publication, account: account, node_platform: platform, git_sha: "sha-a")
      dup = build(:system_disk_image_publication, account: account, node_platform: platform, git_sha: "sha-a")
      expect(dup).not_to be_valid
      expect(first).to be_persisted
    end

    it "allows the same git_sha across different platforms" do
      other_platform = create(:system_node_platform, account: account)
      create(:system_disk_image_publication, account: account, node_platform: platform, git_sha: "sha-x")
      cross = build(:system_disk_image_publication, account: account, node_platform: other_platform, git_sha: "sha-x")
      expect(cross).to be_valid
    end
  end

  describe "state machine (AASM)" do
    let(:pub) { create(:system_disk_image_publication, account: account, node_platform: platform) }

    it "starts in :queued" do
      expect(pub).to be_queued
    end

    it "queued → verifying via start_verifying" do
      pub.start_verifying!
      expect(pub).to be_verifying
    end

    it "queued → awaiting_upload via await_upload" do
      pub.await_upload!
      expect(pub).to be_awaiting_upload
    end

    it "verifying → published guarded on file_object_id present" do
      pub.start_verifying!
      pub.mark_published # no file_object yet
      expect(pub).to be_verifying # transition refused
      expect(pub.aasm.from_state).to eq(:verifying)
    end

    # IMP-6d2dd4533bd7 (mark_published shares reactivate's shape). The test
    # above never checked published_at/verified_at nor persisted — it would
    # not have caught this. Same mechanism as reactivate: aasm 5.5.2 fires an
    # event-level `before` UNCONDITIONALLY, before the guard is evaluated
    # (aasm.rb#aasm_fire_event: fire_default_callbacks at line 102 runs
    # before event.may_fire? at line 104), so an event-level `before` here
    # stamped published_at/verified_at on the in-memory object even when
    # `guard { file_object_id.present? }` failed — and
    # DiskImagePublicationProcessor#publish! calls `publication.mark_published!`
    # bare, return value discarded, inside a transaction that DOES persist
    # publication via other writes in the same transaction.
    it "does not stamp published_at/verified_at when mark_published's guard fails" do
      pub.start_verifying!
      pub.mark_published # no file_object yet — guard fails
      pub.save!

      expect(pub.reload).to be_verifying # transition refused, whiny_transitions:false
      expect(pub.published_at).to be_nil # the forgeable-timestamp trap
      expect(pub.verified_at).to be_nil
    end

    it "verifying → published succeeds when file_object_id is set" do
      published = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      expect(published).to be_published
      expect(published.published_at).to be_present
      expect(published.verified_at).to be_present
    end

    it "mark_published stamps published_at and verified_at on a legitimate transition, " \
       "preserving verified_at's ||= (does not clobber an earlier verification timestamp)" do
      pub.start_verifying!
      earlier_verified_at = 1.hour.ago
      pub.update_columns(verified_at: earlier_verified_at, file_object_id: create(:file_object, account: account).id)

      pub.mark_published!

      expect(pub.reload).to be_published
      expect(pub.published_at).to be_present
      expect(pub.verified_at).to be_within(1.second).of(earlier_verified_at) # ||= preserved it
    end

    it "verifying → failed with error message" do
      pub.start_verifying!
      pub.mark_failed!("cosign verify failed")
      expect(pub).to be_failed
      expect(pub.error_message).to eq("cosign verify failed")
    end

    it "published → retired stamps retired_at" do
      fake_storage_service = instance_double(::FileStorageService, delete_file: true)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)
      published = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      published.retire!
      expect(published).to be_retired
      expect(published.retired_at).to be_present
    end

    it "retired → purged stamps purged_at" do
      fake_storage_service = instance_double(::FileStorageService, delete_file: true)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)
      retired = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
      retired.purge!
      expect(retired).to be_purged
      expect(retired.purged_at).to be_present
    end

    # Regression for fk_rails_416646d33d: purge! used to hard-delete the
    # file_object BEFORE clearing the back-reference a successor publication
    # keeps in prior_file_object_id, raising ActiveRecord::InvalidForeignKey
    # and leaving retention purge permanently unable to reclaim quota.
    it "retired → purged hard-deletes the file_object even when a successor references it as prior_file_object_id" do
      fo = create(:file_object, account: account, filename: "old.img", checksum_sha256: "b" * 64)
      retired = create(:system_disk_image_publication, :retired,
                        account: account, node_platform: platform, file_object: fo)
      successor = create(:system_disk_image_publication, :published,
                          account: account, node_platform: platform, prior_file_object_id: fo.id)

      fake_storage_service = instance_double(::FileStorageService)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)
      allow(fake_storage_service).to receive(:delete_file) do |file_object, **kw|
        file_object.destroy! if kw[:permanent]
        true
      end

      expect { retired.purge! }.not_to raise_error

      expect(retired.reload).to be_purged
      expect(retired.purged_at).to be_present
      expect(retired.file_object_id).to be_nil
      expect(successor.reload.prior_file_object_id).to be_nil
      expect(::FileManagement::Object.exists?(fo.id)).to be false
    end

    it "purge! refuses to delete the file_object that is the platform's active disk image" do
      active = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: active.file_object_id)
      active.update!(status: "retired", retired_at: Time.current)

      fake_storage_service = instance_double(::FileStorageService, delete_file: true)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)

      expect { active.purge! }.to raise_error(/active disk image/)
      expect(fake_storage_service).not_to have_received(:delete_file)
      expect(active.reload).to be_retired
    end

    it "failed → retired stamps retired_at (DK3 stuck-cleanup path)" do
      failed = create(:system_disk_image_publication, :failed, account: account, node_platform: platform)
      failed.retire!
      expect(failed).to be_retired
      expect(failed.retired_at).to be_present
    end

    it "verifying → retired stamps retired_at (DK3 stuck-cleanup path)" do
      pub.start_verifying!
      pub.retire!
      expect(pub).to be_retired
      expect(pub.retired_at).to be_present
    end

    it "rejects invalid transitions silently (whiny_transitions: false)" do
      # queued → published is invalid; should not raise, status stays queued.
      pub.mark_published
      expect(pub).to be_queued
    end

    it "retired → published via reactivate (rollback/promote), clears retired_at" do
      published = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      published.update!(status: "retired", retired_at: 3.days.ago)

      published.reactivate
      published.save!

      expect(published).to be_published
      expect(published.retired_at).to be_nil
    end

    it "does NOT let mark_published reactivate a retired row — only the dedicated reactivate event can (IMP-d4a546024745)" do
      # mark_published is also fired by DiskImagePublicationProcessor for the
      # CI/webhook ingest pipeline; it must stay verifying-only so a replayed
      # webhook can never resurrect an already-retired git_sha.
      published = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      published.update!(status: "retired", retired_at: Time.current)

      published.mark_published
      expect(published).to be_retired # transition refused, whiny_transitions:false
    end

    # IMP-6d2dd4533bd7 — a guard-failing reactivate must not forge
    # published_at. aasm 5.5.2 fires an event-level `before` UNCONDITIONALLY,
    # before the transition guard is even evaluated (verified against the
    # gem source, aasm.rb#aasm_fire_event: fire_default_callbacks at line
    # 102 runs before event.may_fire? at line 104) — so writing the
    # published_at/retired_at update as an event-level `before` (as this
    # code used to) stamped published_at on the in-memory object even when
    # `guard { file_object_id.present? }` failed. The call-and-discard idiom
    # both PromotePublication and RollbackPublication use
    # (`pub.reactivate; pub.save!`, return value never checked) then
    # persisted that forged timestamp on a row that never actually left
    # :retired.
    #
    # This matters beyond internal consistency: UpgradeDispatcher.preflight
    # treats published_at as THE discriminator for "was this row ever
    # legitimately published" (its own comment: "only mark_published and
    # reactivate ever set it ... and nothing clears it"). A forged
    # published_at on a never-published row sails straight past that guard
    # — see the "still refuses" preflight spec in
    # promoted_pointer_publication_state_spec.rb for the dispatch-level
    # consequence.
    it "does not stamp published_at when reactivate's guard fails (retired row, no file_object)" do
      # NOTE: the :retired factory trait sets published_at (it represents a
      # row that genuinely WAS published, then retired) — using it here
      # would make the "stays nil" assertion vacuous. Build the row the way
      # DiskImageRetentionService#retire_stuck! actually produces a retired
      # row that never had a file_object and never went through
      # mark_published: :failed -> retire (not reactivate). That is the
      # real, reachable "never-published, retired, no artifact" shape.
      failed = create(:system_disk_image_publication, :failed, account: account, node_platform: platform)
      failed.retire!
      failed.reload
      expect(failed).to be_retired
      expect(failed.file_object_id).to be_nil
      expect(failed.published_at).to be_nil
      retired_at_before = failed.retired_at
      expect(retired_at_before).to be_present

      failed.reactivate
      failed.save!

      expect(failed.reload).to be_retired # transition refused, whiny_transitions:false
      expect(failed.published_at).to be_nil # the forgeable-timestamp trap
      expect(failed.retired_at).to eq(retired_at_before) # untouched, not cleared
    end
  end

  # White-box guard against the DSL silently dropping the fix: the
  # does-not-stamp specs above would ALSO pass if `after` were misspelled,
  # nested wrong, or otherwise never registered — a missing callback and a
  # correctly-gated one are behaviorally identical on the refusal path. This
  # asserts directly on the built AASM::Core::Transition/Event objects that
  # the write actually lives where it's supposed to (IMP-6d2dd4533bd7).
  describe "reactivate/mark_published timestamp writes are transition-scoped, not event-level" do
    def transition_to_published(event_name)
      event = described_class.aasm.events.find { |e| e.name == event_name }
      event.transitions.find { |t| Array(t.to).include?(:published) }
    end

    it "registers the published_at write as the transition's :after" do
      expect(transition_to_published(:mark_published).options[:after]).to be_present
      expect(transition_to_published(:reactivate).options[:after]).to be_present
    end

    it "carries no event-level :before anymore — the construct that fires before the guard" do
      mp_event = described_class.aasm.events.find { |e| e.name == :mark_published }
      reactivate_event = described_class.aasm.events.find { |e| e.name == :reactivate }
      expect(mp_event.options[:before]).to be_nil
      expect(reactivate_event.options[:before]).to be_nil
    end
  end

  describe "scopes" do
    let!(:queued) { create(:system_disk_image_publication, account: account, node_platform: platform) }
    let!(:published) { create(:system_disk_image_publication, :published, account: account, node_platform: platform) }
    let!(:retired) { create(:system_disk_image_publication, :retired, account: account, node_platform: platform) }
    let!(:retired_old) do
      create(:system_disk_image_publication, :retired, account: account, node_platform: platform).tap do |r|
        r.update_columns(retired_at: 30.days.ago)
      end
    end

    it ".published_state returns only published rows" do
      expect(described_class.published_state).to contain_exactly(published)
    end

    it ".retainable returns published + retired" do
      expect(described_class.retainable).to contain_exactly(published, retired, retired_old)
    end

    it ".purgeable returns retired rows past grace period" do
      expect(described_class.purgeable(grace_days: 7)).to contain_exactly(retired_old)
    end

    it ".recent_for orders by created_at desc and limits" do
      list = described_class.recent_for(platform, 2)
      expect(list.length).to eq(2)
      expect(list.first.created_at).to be >= list.last.created_at
    end
  end

  describe "#cosign_attestation_predicate" do
    it "decodes the base64 + JSON when present" do
      predicate = { "platform_name" => "test", "sha256" => "abc" }
      bundle = Base64.strict_encode64(predicate.to_json)
      pub = create(:system_disk_image_publication, account: account, node_platform: platform, attestation_bundle: bundle)
      expect(pub.cosign_attestation_predicate).to eq(predicate)
    end

    it "returns nil when attestation_bundle is blank" do
      pub = create(:system_disk_image_publication, account: account, node_platform: platform, attestation_bundle: nil)
      expect(pub.cosign_attestation_predicate).to be_nil
    end

    it "returns nil on malformed bundle (no exception)" do
      pub = create(:system_disk_image_publication, account: account, node_platform: platform, attestation_bundle: "not-base64")
      expect(pub.cosign_attestation_predicate).to be_nil
    end
  end

  describe "#active?" do
    it "true when published AND platform.disk_image_file_object_id matches" do
      published = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: published.file_object_id)
      expect(published.active?).to be true
    end

    it "false when retired even if file_object matches" do
      retired = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
      platform.update!(disk_image_file_object_id: retired.file_object_id)
      expect(retired.active?).to be false
    end
  end

  # Guards PromotePublication / RollbackPublication's boot-pointer write.
  # Two independent halves — every example below is chosen to isolate ONE
  # half so a mutant dropping either check in isolation still fails (a
  # purged row alone fails BOTH halves at once and can't prove that).
  describe "#promotable?" do
    it "true for published with its artifact present" do
      pub = create(:system_disk_image_publication, :published, account: account, node_platform: platform)
      expect(pub.promotable?).to be true
    end

    it "true for retired with its artifact present" do
      fo = create(:file_object, account: account)
      pub = create(:system_disk_image_publication, :retired, account: account, node_platform: platform, file_object: fo)
      expect(pub.promotable?).to be true
    end

    it "false for queued (no artifact, wrong status)" do
      pub = create(:system_disk_image_publication, account: account, node_platform: platform)
      expect(pub.promotable?).to be false
    end

    it "false for awaiting_upload (no artifact, wrong status)" do
      pub = create(:system_disk_image_publication, :awaiting_upload, account: account, node_platform: platform)
      expect(pub.promotable?).to be false
    end

    it "false for failed (no artifact, wrong status)" do
      pub = create(:system_disk_image_publication, :failed, account: account, node_platform: platform)
      expect(pub.promotable?).to be false
    end

    it "false for purged — published_at is stale (purge! leaves it set) and file_object_id is nil " \
       "(purge! hard-deletes it), status flips to purged" do
      fake_storage_service = instance_double(::FileStorageService, delete_file: true)
      allow(::FileStorageService).to receive(:new).and_return(fake_storage_service)
      retired = create(:system_disk_image_publication, :retired, account: account, node_platform: platform)
      retired.purge!
      expect(retired.published_at).to be_present # the published_at-only-guard trap
      expect(retired.promotable?).to be false
    end

    it "false for retired with NO artifact — status passes, artifact fails. Produced by " \
       "DiskImageRetentionService#retire_stuck! retiring a :failed/:verifying CI run that " \
       "never got a file_object; also the row SystemFleetTool#previous_disk_image_publication " \
       "auto-selects (\"newest retired\") when no publication_id is given." do
      stuck = create(:system_disk_image_publication, :failed, account: account, node_platform: platform,
                                                                created_at: 30.days.ago)
      stuck.retire!
      expect(stuck.reload.status).to eq("retired")
      expect(stuck.file_object_id).to be_nil
      expect(stuck.promotable?).to be false
    end

    it "false for :verifying with an artifact already uploaded but NOT yet cosign/sha verified " \
       "(direct-upload mode, DiskImagePublicationProcessor#direct_upload_mode?) — artifact " \
       "passes, status fails" do
      fo = create(:file_object, account: account)
      pub = create(:system_disk_image_publication, :verifying, account: account, node_platform: platform,
                                                                 oci_ref: nil, file_object: fo)
      expect(pub.promotable?).to be false
    end
  end

  # IMP-9d95e4c202f5 — aasm fires an EVENT-LEVEL `before` unconditionally,
  # before from-state matching, and whiny_transitions:false makes the
  # non-matching call a silent no-op — so retire/purge/mark_failed stamped
  # timestamps and error text on rows whose status never changed. Same shape
  # IMP-6d2dd4533bd7 fixed for mark_published/reactivate.
  describe "no-op event calls stamp nothing" do
    it "retire on a purged row leaves retired_at untouched" do
      pub = create(:system_disk_image_publication, status: "purged")
      pub.retire
      expect(pub.status).to eq("purged")
      expect(pub.retired_at).to be_nil
    end

    it "purge on a published row leaves purged_at untouched" do
      pub = create(:system_disk_image_publication, status: "published")
      pub.purge
      expect(pub.status).to eq("published")
      expect(pub.purged_at).to be_nil
    end

    it "mark_failed on a published row records no error message" do
      pub = create(:system_disk_image_publication, status: "published")
      pub.mark_failed("boom")
      expect(pub.status).to eq("published")
      expect(pub.error_message).to be_nil
    end

    it "retire from published still stamps retired_at" do
      pub = create(:system_disk_image_publication, status: "published")
      pub.retire
      expect(pub.status).to eq("retired")
      expect(pub.retired_at).to be_present
    end

    it "purge from retired still stamps purged_at" do
      pub = create(:system_disk_image_publication, status: "retired", retired_at: 10.days.ago)
      pub.purge
      expect(pub.status).to eq("purged")
      expect(pub.purged_at).to be_present
    end

    it "mark_failed from verifying still records the error argument" do
      pub = create(:system_disk_image_publication, status: "verifying")
      pub.mark_failed("cosign verify failed")
      expect(pub.status).to eq("failed")
      expect(pub.error_message).to eq("cosign verify failed")
    end

    # Closes the CLASS, not just the instances: a fifth event with an
    # event-level `before` reintroduces the defect wholesale.
    it "declares no event-level before callbacks on any event" do
      offenders = described_class.aasm.events.select do |event|
        event.options[:before].present?
      end.map(&:name)
      expect(offenders).to be_empty,
        "events with event-level before callbacks (fire before from-state matching): #{offenders.inspect}"
    end
  end
end
