# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::PackageRepositoryBackgroundSync do
  let(:account) { create(:account) }
  let!(:r1) { create(:system_package_repository, account: account, name: "r1") }
  let!(:r2) { create(:system_package_repository, account: account, name: "r2") }

  it "syncs each repository id sequentially, threading force through" do
    expect(System::PackageRepositorySyncService).to receive(:call)
      .with(repository: r1, force: true).ordered
    expect(System::PackageRepositorySyncService).to receive(:call)
      .with(repository: r2, force: true).ordered

    described_class.run!(repository_ids: [ r1.id, r2.id ], force: true)
  end

  it "defaults force to false and skips unknown ids" do
    expect(System::PackageRepositorySyncService).to receive(:call).with(repository: r1, force: false)

    described_class.run!(repository_ids: [ "00000000-0000-0000-0000-000000000000", r1.id ])
  end

  it "rescues a per-repo failure so one bad repo does not stop the rest" do
    allow(System::PackageRepositorySyncService).to receive(:call)
      .with(repository: r1, force: false).and_raise(StandardError, "boom")
    expect(System::PackageRepositorySyncService).to receive(:call).with(repository: r2, force: false)

    expect { described_class.run!(repository_ids: [ r1.id, r2.id ]) }.not_to raise_error
  end
end
