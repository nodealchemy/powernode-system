# frozen_string_literal: true

# Shared examples for cloud provider adapter contract compliance.
#
# Each adapter must implement:
#   - The BaseProvider interface (existence + arity)
#   - Status normalization (maps cloud-specific states → BaseProvider::STATUSES)
#   - Typed error contract (raises BaseProvider::ProviderError family on
#     auth/rate/not-found/quota/transport failures rather than returning
#     `{ success: false }` hashes — see audit S2/D4)
#
# These groups are designed to be opt-in so adapter specs can adopt them
# incrementally as their internals stabilize.

# Group 1: Method existence on the BaseProvider contract.
# Cheap smoke test that catches accidental method removal during refactors.
RSpec.shared_examples "a cloud provider" do
  describe "interface compliance" do
    # Core lifecycle
    it { is_expected.to respond_to(:provider_type) }
    it { is_expected.to respond_to(:create_instance) }
    it { is_expected.to respond_to(:terminate_instance) }
    it { is_expected.to respond_to(:start_instance) }
    it { is_expected.to respond_to(:stop_instance) }
    it { is_expected.to respond_to(:reboot_instance) }
    it { is_expected.to respond_to(:get_instance) }
    it { is_expected.to respond_to(:list_instances) }

    # Volumes
    it { is_expected.to respond_to(:create_volume) }
    it { is_expected.to respond_to(:delete_volume) }
    it { is_expected.to respond_to(:attach_volume) }
    it { is_expected.to respond_to(:detach_volume) }
    it { is_expected.to respond_to(:get_volume) }

    # IP
    it { is_expected.to respond_to(:allocate_ip) }
    it { is_expected.to respond_to(:release_ip) }
    it { is_expected.to respond_to(:associate_ip) }
    it { is_expected.to respond_to(:disassociate_ip) }

    # Images
    it { is_expected.to respond_to(:create_image) }
    it { is_expected.to respond_to(:delete_image) }
    it { is_expected.to respond_to(:get_image) }
  end

end

# Signature compliance is asserted at the class level (not against any
# adapter subject) so it composes cleanly with adapter specs that stub
# their subject. Run once globally, not per-adapter.
RSpec.shared_examples "a provider class with BaseProvider signatures" do
  let(:adapter_class) { described_class }

  # detach_volume must accept (volume_id, force:) — Azure's pre-fix shape
  # was (volume_id, instance_id) which silently broke polymorphism (audit S2).
  it "detach_volume signature is (volume_id, force:)" do
    params = adapter_class.instance_method(:detach_volume).parameters
    expect(params.first).to eq([:req, :volume_id])
    expect(params).to include([:key, :force])
  end

  # reboot_instance, not restart_instance — Azure's pre-fix name diverged.
  it "implements reboot_instance (not restart_instance)" do
    expect(adapter_class.instance_methods).to include(:reboot_instance)
    expect(adapter_class.instance_methods).not_to include(:restart_instance)
  end

  # attach_volume must accept (volume_id, instance_id, device:)
  it "attach_volume signature is (volume_id, instance_id, device:)" do
    params = adapter_class.instance_method(:attach_volume).parameters
    expect(params[0]).to eq([:req, :volume_id])
    expect(params[1]).to eq([:req, :instance_id])
    expect(params).to include([:key, :device])
  end
end

# Group 2: Status normalization. Each adapter spec passes a hash mapping
# cloud-side status strings to expected platform output.
#
#   it_behaves_like "a cloud provider with status normalization", {
#     "running" => "running",
#     "stopped" => "stopped"
#   }
RSpec.shared_examples "a cloud provider with status normalization" do |cloud_to_platform|
  describe "#normalize_status" do
    cloud_to_platform.each do |cloud_status, expected_platform_status|
      it "maps #{cloud_status.inspect} to #{expected_platform_status.inspect}" do
        # normalize_status is protected; use send to bypass for the spec.
        actual = subject.send(:normalize_status, cloud_status)
        expect(actual).to eq(expected_platform_status)
      end
    end

    it "produces only platform-known statuses for all mapped values" do
      known = ::System::Providers::BaseProvider::STATUSES.values
      cloud_to_platform.values.uniq.each do |platform_status|
        expect(known).to include(platform_status),
                         "Adapter mapped to #{platform_status.inspect} which is not in BaseProvider::STATUSES"
      end
    end

    it "falls back to 'unknown' for unmapped statuses" do
      actual = subject.send(:normalize_status, "this-status-does-not-exist-anywhere")
      expect(actual).to eq("unknown")
    end
  end
end

# Group 3: Typed error contract. Each adapter spec sets up a failure mode
# (mocking its underlying client to raise/respond with auth failure) and
# the shared example verifies the adapter raises the right typed exception
# rather than returning a hash.
#
#   it_behaves_like "a cloud provider with typed errors" do
#     before { stub_auth_failure_on(subject) }
#   end
#
# The adapter spec is responsible for stubbing — this just asserts the
# exception family.
RSpec.shared_examples "a cloud provider raises on auth failure" do
  it "raises AuthenticationError on 401/403" do
    expect { trigger_auth_failure }
      .to raise_error(::System::Providers::BaseProvider::AuthenticationError)
  end

  it "does not return a {success: false} hash on auth failure" do
    expect { trigger_auth_failure }.to raise_error(::System::Providers::BaseProvider::ProviderError)
  end
end

RSpec.shared_examples "a cloud provider raises on rate limit" do
  it "raises RateLimitError on 429" do
    expect { trigger_rate_limit }
      .to raise_error(::System::Providers::BaseProvider::RateLimitError)
  end
end

RSpec.shared_examples "a cloud provider raises on not found" do
  it "raises ResourceNotFoundError on 404" do
    expect { trigger_not_found }
      .to raise_error(::System::Providers::BaseProvider::ResourceNotFoundError)
  end
end

# Group 4: Required-credential validation. Adapters using the
# BaseProvider#credential helper with `required: true` should raise
# AuthenticationError when the connection is missing the required field.
#
#   it_behaves_like "a cloud provider validates credentials" do
#     let(:missing_field_setup) { connection.access_key = nil }
#   end
RSpec.shared_examples "a cloud provider validates credentials" do
  it "raises AuthenticationError when a required credential is missing" do
    expect { trigger_credential_check }
      .to raise_error(::System::Providers::BaseProvider::AuthenticationError, /credential/i)
  end
end
