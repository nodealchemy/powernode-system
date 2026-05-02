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

  # Note: cloud provider SDKs (aws-sdk-ec2, google-cloud-compute, fog-openstack,
  # azure_mgmt_compute) and net-ssh are added to server/Gemfile in task 3,
  # following the platform convention (extension gemspecs stay sparse;
  # heavy runtime deps live in the core Gemfile).
end
