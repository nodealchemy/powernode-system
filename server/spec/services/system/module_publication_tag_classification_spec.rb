# frozen_string_literal: true

require "rails_helper"

# IMP-f4c91ad6c0d3. system_module_publication_integrity reported
# powernode-hub-frontend dirty on every call, listing ~130 "unrecorded" tags.
# An always-dirty checker is unreadable in exactly the way an always-red gate
# is: the next genuinely unrecorded publication arrives inside a list everyone
# has learned to ignore.
#
# TWO defects, and the first is in the checker itself. `unrecorded_tags` was a
# raw set difference over EVERY tag in the repo. Cosign stores its signatures
# as tags in the SAME repo (`sha256-<digest>.sig`, and a bare `sha256-<digest>`
# referrer), so ~85 of those ~130 entries can never have a NodeModuleVersion by
# construction — they are not module publications at all. `latest` is a
# floating alias of a tag already counted.
#
# Excluding those is NOT the ignore list the operator direction rules out: they
# are still reported, under non_publication_tags, so nothing is hidden. What
# changes is that they stop being counted as gaps.
#
# The SECOND defect — ~50 genuine build tags that were never recorded — is NOT
# fixed here. The obvious back-fill (reuse ModulePublicationProcessor with
# promote: false, which does leave current_version_id alone) turns out to be
# unsafe for two reasons that only show up in the processor's ordering:
#   * module_publication_processor.rb:56 creates the NodeModuleVersion BEFORE
#     the cosign verification at :63, and the failure branch never removes it —
#     so a tag that FAILS verification would still be recorded, and this very
#     checker would then report it clean. That inverts "skip rather than guess"
#     into exactly the invisible lie it was meant to prevent.
#   * module_publication_processor.rb:55 calls refresh_manifest! unconditionally,
#     which re-imports that tag's historical manifest over the LIVE module —
#     mask, file_spec, services, sudoers, skills. Replaying ~50 tags would leave
#     the module carrying an arbitrary old manifest, last-one-wins.
# Blocked for a design decision; see the task report.
RSpec.describe "module publication integrity classification" do
  let(:account)  { create(:account) }
  let(:platform) { create(:system_node_platform, account: account) }
  let(:category) { create(:system_node_module_category, account: account, variety: "subscription") }

  def a_module(name, repo: "powernode/#{name}")
    create(:system_node_module,
           account: account, node_platform: platform, category: category,
           name: name, variety: "subscription", gitea_repo_full_name: repo)
  end

  def a_version(node_module, tag)
    create(:system_node_module_version, node_module: node_module, config: { "git_tag" => tag })
  end

  def stub_tags(*tags)
    allow(Open3).to receive(:capture3)
      .with(hash_including("DOCKER_CONFIG"), "oras", "repo", "tags", anything)
      .and_return([ tags.join("\n"), "", instance_double(Process::Status, success?: true, exitstatus: 0) ])
  end

  before do
    allow(System::DiskImageRegistryConfig).to receive(:registry_host).and_return("git.example.org")
    allow(System::DiskImageRegistryConfig).to receive(:registry_user).and_return(nil)
    allow(System::DiskImageRegistryConfig).to receive(:registry_token).and_return(nil)
  end

  describe System::ModulePublicationIntegrityService do
    subject(:service) { described_class.new(account: account) }

    it "does not count cosign signature tags as unrecorded publications" do
      mod = a_module("hub-frontend")
      a_version(mod, "abc1234")
      stub_tags("abc1234",
                "sha256-046c6c2f0a036fbe54649216f930065b8ed5c7bfe7d83cf01d7c722ea4bae562.sig",
                "sha256-262e7d38af884a1d489bf50faef4945ceb0aadb886b2a55e73df61cda7eca316")

      finding = service.check(module_name: "hub-frontend").first

      expect(finding.unrecorded_tags).to be_empty
      expect(finding).to be_ok
    end

    it "does not count the floating `latest` alias as a publication" do
      mod = a_module("hub-frontend")
      a_version(mod, "abc1234")
      stub_tags("abc1234", "latest")

      expect(service.check(module_name: "hub-frontend").first.unrecorded_tags).to be_empty
    end

    # The excluded tags must remain visible, or this becomes the ignore list
    # the operator direction forbids.
    it "still reports the excluded tags, so nothing is hidden" do
      mod = a_module("hub-frontend")
      a_version(mod, "abc1234")
      stub_tags("abc1234", "latest", "sha256-deadbeef.sig")

      finding = service.check(module_name: "hub-frontend").first
      expect(finding.non_publication_tags).to contain_exactly("latest", "sha256-deadbeef.sig")
    end

    it "STILL reports a genuine unrecorded build tag" do
      mod = a_module("hub-frontend")
      a_version(mod, "abc1234")
      stub_tags("abc1234", "def5678", "sha256-deadbeef.sig")

      finding = service.check(module_name: "hub-frontend").first
      expect(finding.unrecorded_tags).to contain_exactly("def5678")
      expect(finding).not_to be_ok,
        "suppressing cosign noise must not suppress the finding the checker exists for"
    end
  end
end
