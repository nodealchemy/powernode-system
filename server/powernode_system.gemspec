# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name        = "powernode_system"
  spec.version     = "0.1.0"
  spec.authors     = ["Everett C. Haimes III"]
  spec.summary     = "Powernode Infrastructure Extension"
  spec.description = "Operator-side execution of System:: infrastructure operations: cloud provisioning, SSH execution, module distribution, volume management."
  spec.license     = "Proprietary"
  spec.files       = Dir["app/**/*", "config/**/*", "db/**/*", "lib/**/*"]

  spec.add_dependency "rails", "~> 8.1"

  # Note: extension gemspecs stay sparse — heavy runtime deps live in the core
  # Gemfile (server/Gemfile). The optional cloud provider SDKs are not there.
  #
  # aws-sdk-ec2, google-cloud-compute and fog-openstack are not bundled, so the
  # AwsProvider / GcpProvider / OpenStackProvider adapters cannot run in this
  # build. They declare their gem via BaseProvider.required_sdk_gem and
  # System::Providers::Registry hides them from #available_providers and
  # refuses in front of the caller (APO-7) rather than raising NameError at
  # first use. Bundle the gem in server/Gemfile to turn one back on.
  #
  # azure_mgmt_compute is deliberately never bundled: it pins faraday < 2.0
  # against the platform's faraday ~> 2.0, so AzureProvider is a hand-rolled
  # REST client on the core faraday stack and needs no SDK gem.
end
