# frozen_string_literal: true

# Seeds entity-type anchors in the knowledge graph for system extension
# concepts. The existing system_fleet_kg_schema.rb seeds three concept-
# level anchors (FleetSignal, RemediationOutcome, ModuleProvenance);
# this complements with operator-facing ENTITY anchors so the KG can
# express relationships like "Module ASSIGNED_TO Node" or
# "KubernetesCluster BACKED_BY NodeInstance".
#
# These anchors give Ai::KnowledgeGraphExtractor a typed receiving
# point — when it processes a runtime event like "instance i-abc just
# joined cluster X", it links the extracted instance + cluster
# entities back to these type anchors.
#
# Per-account scoped (mirrors system_fleet_kg_schema.rb pattern).
#
# Spicy-bear plan slice 4.

puts "\n  Seeding System extension KG entity anchors..."

# ─────────────────────────────────────────────────────────────────────
# Entity-type anchors — per-domain typed nodes that runtime extraction
# attaches edges to.
# ─────────────────────────────────────────────────────────────────────
ENTITY_ANCHORS = [
  # Node lifecycle (4)
  { name: "System::Node",         description: "Node — physical or virtual host registered to a Template + Architecture + Platform" },
  { name: "System::NodeInstance", description: "NodeInstance — concrete provisioned instance of a Node; carries the agent" },
  { name: "System::NodeTemplate", description: "NodeTemplate — composition spec (modules + boot config) that NodeInstances are provisioned from" },
  { name: "System::NodeArchitecture", description: "NodeArchitecture — hardware target (amd64, arm64) with kernel + initramfs artifacts" },

  # Module catalog (2)
  { name: "System::NodeModule",   description: "NodeModule — versioned, OCI-published module with package_spec + protected_spec; subscription/config/instance varieties" },
  { name: "System::NodeModuleAssignment", description: "NodeModuleAssignment — Node↔Module link with priority + enabled flag" },

  # SDWAN (4)
  { name: "Sdwan::Network",        description: "SDWAN overlay network — IPv6 ULA /64; routing_protocol=static|ibgp" },
  { name: "Sdwan::Peer",           description: "SDWAN peer — NodeInstance's WireGuard membership in a network with /128 overlay address" },
  { name: "Sdwan::FederationPeer", description: "Federation peer — cross-account SDWAN trust relationship with JWT-signed advertisements" },
  { name: "Sdwan::VirtualIp",      description: "VirtualIP — anycast or single-holder address advertised by one or more peers via iBGP" },

  # Container runtimes (3, Phase 1+2)
  { name: "Devops::DockerHost",        description: "Docker host — registered docker daemon (managed = NodeInstance-backed; external = operator-registered)" },
  { name: "Devops::KubernetesCluster", description: "Kubernetes cluster — flavor=k3s|kubeadm; api_endpoint on SDWAN overlay; multiple member nodes" },
  { name: "Devops::KubernetesNode",    description: "Kubernetes cluster member — joins NodeInstance to KubernetesCluster with role=server|agent|control_plane|worker" }
].freeze

# ─────────────────────────────────────────────────────────────────────
# Relationship-type anchors — concept nodes representing recurring
# relationship semantics. Edges in the graph use relation_type strings
# directly; these anchors give documentation + UI grouping for the
# relationship vocabulary.
# ─────────────────────────────────────────────────────────────────────
RELATION_ANCHORS = [
  { name: "ASSIGNED_TO",   description: "Module ASSIGNED_TO Node — NodeModule appears in a Node's effective module list" },
  { name: "PROVISIONED_AS", description: "NodeTemplate PROVISIONED_AS NodeInstance — instances inherit the template's modules" },
  { name: "ATTACHED_TO",   description: "Sdwan::Peer ATTACHED_TO Sdwan::Network — peer is a member of the network" },
  { name: "MEMBER_OF",     description: "NodeInstance MEMBER_OF KubernetesCluster — node joined as server or agent" },
  { name: "BACKED_BY",     description: "Devops::DockerHost BACKED_BY NodeInstance — managed host's lifecycle bound to instance" },
  { name: "ADVERTISES",    description: "Sdwan::Peer ADVERTISES Sdwan::VirtualIp — peer is a holder for the VIP" },
  { name: "FEDERATES_WITH", description: "Account FEDERATES_WITH FederationPeer — cross-account SDWAN trust" }
].freeze

entity_count = 0
relation_count = 0

Account.find_each do |account|
  # Entity-type anchors — node_type=entity, entity_type=type-name
  ENTITY_ANCHORS.each do |attrs|
    node = ::Ai::KnowledgeGraphNode.find_or_initialize_by(
      account: account, name: attrs[:name], node_type: "entity"
    )
    was_new = node.new_record?
    node.assign_attributes(
      description: attrs[:description],
      # entity_type enum is fixed (person, organization, technology, ...);
      # "custom" matches the existing system_fleet_kg_schema pattern.
      # Concrete model name is preserved in `name` + properties.
      entity_type: "custom",
      status: "active",
      confidence: 1.0,
      properties: {
        "system_anchor" => true,
        "system_class" => attrs[:name],
        "domain" => attrs[:name].split("::").first.downcase,
        "seeded_by" => "system_kg_entities_seed"
      }
    )
    if was_new || node.changed?
      node.save!
      entity_count += 1 if was_new
    end
  end

  # Relationship-type anchors — node_type=relation
  RELATION_ANCHORS.each do |attrs|
    node = ::Ai::KnowledgeGraphNode.find_or_initialize_by(
      account: account, name: attrs[:name], node_type: "relation"
    )
    was_new = node.new_record?
    node.assign_attributes(
      description: attrs[:description],
      entity_type: "custom",
      status: "active",
      confidence: 1.0,
      properties: {
        "system_anchor" => true,
        "seeded_by" => "system_kg_entities_seed"
      }
    )
    if was_new || node.changed?
      node.save!
      relation_count += 1 if was_new
    end
  end
end

puts "  ✅ Entity anchors: #{entity_count} new across #{Account.count} account(s)"
puts "  ✅ Relation anchors: #{relation_count} new across #{Account.count} account(s)"
puts "  Done seeding System extension KG entity anchors."
