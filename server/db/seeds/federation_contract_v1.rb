# frozen_string_literal: true

# Loads the Social Contract v1 markdown file into a
# FederationContractVersion DB row so federation handshakes have a
# concrete `contract_version_agreed: 1` reference. The text is loaded
# verbatim and SHA-256-digested by the model's before_validation hook.
#
# Re-running is safe: the seed checks for an existing v1 record + digest
# match before creating.
#
# Plan reference: Decentralized Federation §"Social Contracts" + P4.6.

puts "\n  Seeding Federation Social Contract v1..."

contract_path = File.expand_path("../../../docs/federation/SOCIAL_CONTRACT.md", __dir__)
unless File.exist?(contract_path)
  puts "    ⚠ SOCIAL_CONTRACT.md not found at #{contract_path}; skipping."
  return
end

contract_text = File.read(contract_path)
contract_digest = Digest::SHA256.hexdigest(contract_text)

existing = System::FederationContractVersion.find_by(version: 1)

if existing
  if existing.contract_digest == contract_digest
    puts "    ✓ v1 already present; digest matches (#{contract_digest[0, 12]}...)"
  else
    puts "    ⚠ v1 already present but contract_text has changed since last seed."
    puts "      Existing digest: #{existing.contract_digest[0, 12]}..."
    puts "      Current  digest: #{contract_digest[0, 12]}..."
    puts "      The contract text is immutable per-version. To revise, bump to v2 + deprecate v1."
  end
else
  System::FederationContractVersion.create!(
    version: 1,
    contract_text: contract_text,
    effective_at: Date.new(2026, 5, 14),
    metadata: {
      "source_file" => "extensions/system/docs/federation/SOCIAL_CONTRACT.md",
      "commitments" => 12,
      "enforcement_categories" => %w[soft hard critical]
    }
  )
  puts "    ✓ Created v1 (#{contract_text.bytesize} bytes, digest #{contract_digest[0, 12]}...)"
end
