# frozen_string_literal: true

require "rails_helper"

# Extension half of compose-time prerequisite validation (IMP 019fe647):
# answers core's "can this plan's skills actually run against this template?"
# question. First rule: overlay-requiring skills (docker_provision) need the
# chosen template to declare a live Sdwan::Network — the dryrun-20260809c
# failure shape, knowable at compose time.
RSpec.describe System::ProvisionPrerequisites do
  let(:account) { create(:account) }
  let(:network) { create(:sdwan_network, account: account) }
  let(:template) do
    create(:system_node_template, account: account, name: "wired",
                                  config: { "boot_mode" => "uefi_disk", "sdwan_network_id" => network.id })
  end

  def check(skills:, template_id: template.id, **kwargs)
    described_class.check(account: account, template_id: template_id, skills: skills, **kwargs)
  end

  it "passes a wired template for docker_provision" do
    expect(check(skills: %w[provision_full_stack docker_provision])).to eq([])
  end

  it "passes any template when no overlay-requiring skill is planned" do
    bare = create(:system_node_template, account: account, name: "bare", config: {})
    expect(check(skills: %w[provision_full_stack], template_id: bare.id)).to eq([])
  end

  it "flags a template with no sdwan_network_id when docker_provision is planned" do
    bare = create(:system_node_template, account: account, name: "bare2", config: {})
    issues = check(skills: %w[docker_provision], template_id: bare.id)
    expect(issues.join).to match(/sdwan_network_id|SDWAN/i)
  end

  it "flags a declared network that does not exist" do
    ghost = create(:system_node_template, account: account, name: "ghost",
                                          config: { "sdwan_network_id" => SecureRandom.uuid })
    issues = check(skills: %w[docker_provision], template_id: ghost.id)
    expect(issues.join).to match(/does not exist|not found/i)
  end

  it "flags a declared network belonging to another account" do
    foreign = create(:sdwan_network, account: create(:account))
    leaky = create(:system_node_template, account: account, name: "leaky",
                                          config: { "sdwan_network_id" => foreign.id })
    issues = check(skills: %w[docker_provision], template_id: leaky.id)
    expect(issues.join).to match(/does not exist|not found/i)
  end

  it "flags an unresolvable template id" do
    issues = check(skills: %w[docker_provision], template_id: SecureRandom.uuid)
    expect(issues.join).to match(/template/i)
  end

  # IMP-94728a788498: the composer resolves the network THREE-ARMED
  # (template explicit → account default → networkless) and passes the
  # result down, so composer and checker agree BY CONSTRUCTION — the checker
  # must not recompute the resolution from the template alone and disagree.
  # Omitting the kwarg keeps the legacy template-only read (the specs above).
  describe "the caller-resolved network contract (IMP-94728a788498)" do
    it "passes when the caller-resolved network exists (the account-default arm)" do
      bare = create(:system_node_template, account: account, name: "bare-resolved", config: {})
      expect(check(skills: %w[docker_provision], template_id: bare.id,
                   network_id: network.id)).to eq([])
    end

    it "flags a caller-resolved network that does not exist for this account" do
      issues = check(skills: %w[docker_provision], network_id: SecureRandom.uuid)
      expect(issues.join).to match(/does not exist|not found/i)
    end

    it "flags a caller-resolved network belonging to another account" do
      foreign = create(:sdwan_network, account: create(:account))
      issues = check(skills: %w[docker_provision], network_id: foreign.id)
      expect(issues.join).to match(/does not exist|not found/i)
    end

    it "flags an explicit nil resolution — nothing resolves for this plan" do
      bare = create(:system_node_template, account: account, name: "bare-nil", config: {})
      issues = check(skills: %w[docker_provision], template_id: bare.id, network_id: nil)
      expect(issues.join).to match(/no .*network resolves|sdwan_network_id/i)
    end

    it "trusts the caller's resolution over the template's own declaration" do
      # `template` declares network.id; the caller's resolution wins — there
      # is exactly ONE resolver, and it is the composer.
      other = create(:sdwan_network, account: account)
      expect(check(skills: %w[docker_provision], network_id: other.id)).to eq([])
    end
  end
end
