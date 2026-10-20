# frozen_string_literal: true

require "rails_helper"

# RepoSyncService execs `git` (and git execs `ssh`) inside the Rails process,
# so the hub-backend module must ship both binaries: neither runtime-ruby nor
# base-os-ubuntu-noble provides them.
RSpec.describe "powernode-hub-backend module package_spec" do
  let(:manifest) do
    YAML.safe_load(
      File.read(Rails.root.join("../extensions/system/modules/powernode-hub-backend/manifest.yaml")),
      aliases: true
    )
  end

  it "includes git and openssh-client for the GitOps repo sync" do
    expect(manifest["package_spec"]).to include("git", "openssh-client")
  end
end
