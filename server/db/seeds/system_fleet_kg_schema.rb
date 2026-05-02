# frozen_string_literal: true

# Seeds the predeclared knowledge-graph node anchors for fleet-domain
# extraction. Three concept-level nodes act as roots that the
# LearningExtractor (M8) and MD-2 audit/CVE pipelines link entities to:
#
#   - FleetSignal       — instance silent / module drift / cert expiring
#                         observations and their fingerprints
#   - RemediationOutcome — outcomes of dispatched system.* tasks
#                          (success/failure, duration, follow-on signals)
#   - ModuleProvenance  — OCI-digest-rooted provenance chain (SBOM, SLSA
#                          attestation, cosign identity, build pipeline)
#
# Per-account scoping: Each account gets its own seeded triplet so that
# extraction stays tenant-isolated and the KG topology mirrors the
# account/team boundaries already established for compound learnings.
#
# Idempotent: re-running this seed updates descriptions but never duplicates.

puts "\n  Seeding Fleet KG schema (FleetSignal + RemediationOutcome + ModuleProvenance)..."

ANCHOR_NODES = [
  {
    name: "FleetSignal",
    description: "Anchor for fleet sensor signals (instance_silent, module_drift, " \
                 "cert_expiring, module_promotion_ready, config_drift). Children link " \
                 "to specific signal fingerprints and their resolutions.",
    entity_type: "custom"
  },
  {
    name: "RemediationOutcome",
    description: "Anchor for outcomes of dispatched fleet remediation actions. " \
                 "Captures success/failure, duration, and follow-on signals so " \
                 "the autonomy reconciler can learn which interventions work.",
    entity_type: "custom"
  },
  {
    name: "ModuleProvenance",
    description: "Anchor for module supply-chain provenance. Each child links " \
                 "an OCI digest to its SBOM, SLSA attestation, cosign identity, " \
                 "and build pipeline. Used by CVE response and compliance " \
                 "snapshot generation.",
    entity_type: "custom"
  }
].freeze

Account.find_each do |account|
  ANCHOR_NODES.each do |attrs|
    node = Ai::KnowledgeGraphNode.find_or_initialize_by(
      account: account,
      name: attrs[:name],
      node_type: "concept"
    )

    node.assign_attributes(
      description: attrs[:description],
      entity_type: attrs[:entity_type],
      status: "active",
      confidence: 1.0,
      mention_count: node.mention_count.to_i,
      properties: { "fleet_anchor" => true, "seeded_by" => "system_fleet_kg_schema" }
    )

    if node.new_record? || node.changed?
      node.save!
    end
  end
end

count = Ai::KnowledgeGraphNode.where(name: ANCHOR_NODES.map { |n| n[:name] }).count
puts "  ✅ Fleet KG anchors: #{count} node(s) ensured across #{Account.count} account(s)"
