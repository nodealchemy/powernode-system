# frozen_string_literal: true

require "rails_helper"

# IMP-2dd87ade5010 — a worked example that calls an MCP verb with parameters
# the tool does not accept fails at the moment an operator is trusting it most,
# and teaches a wrong mental model of the API surface before it fails.
#
# module-authoring.md and 02-first-module.md documented
# system_promote_module_version as ({ id:, to: }) and
# system_list_module_versions as ({ module_name: }); the declared parameters are
# module_version_id/target_state and module_id. The name form is worse than a
# rejected key: list_module_versions' executor calls account_modules.find, so a
# module NAME raises RecordNotFound rather than returning the documented list.
#
# The pin is mechanical, not a spelling test: it parses every
# `platform.<verb>({ ... })` example in the covered files and checks the
# top-level keys — and each one's value SHAPE — against that verb's OWN
# action_definitions, resolved through PlatformApiToolRegistry::TOOLS. It therefore keeps working when a parameter
# is renamed in the tool, which is the drift that produced this finding.
#
# What it does NOT cover:
#   * RESPONSE shape — and NOT for want of trying. IMP-ef37749c19f8 asked
#     whether this parser could be extended to assert the `// → { ... }`
#     comments' RETURN keys against what handlers emit, the way it asserts
#     parameters against declarations. Measured, tree-wide, the answer is NO,
#     for five independent reasons. Ranked by how fatal:
#
#       1. THERE IS NO DECLARATION TO COMPARE AGAINST. The parameter check
#          works because `action_definitions[verb][:parameters]` IS the
#          contract. Nothing on the return side plays that role. Measured on
#          this tree (66 tool classes, 606 actions): every action definition
#          carries exactly `:description` and `:parameters` — plus `:name` on
#          5 and `:requires_approval` on 2 — and every class-level
#          `.definition` carries exactly `:name`/`:description`/`:parameters`.
#          Zero declare a return or output shape. Nor does one arrive later:
#          `McpTool#output_schema` is a hardcoded `{}` stub with no backing
#          column (mcp_tool.rb:105-107), so the `mcp_tools` row cannot carry
#          one either.
#
#          What clients actually receive for `outputSchema`, on BOTH transports,
#          is verb-independent by construction:
#            * streamable HTTP — the transport real MCP clients use — never
#              calls `build_manifest`. `decorate_tool_entry` takes an
#              `output_schema:` keyword from its caller — the platform family
#              passes `McpPlatformToolRegistrar.default_output_schema`, the
#              introspection family passes `GENERIC_OBJECT_SCHEMA` — for
#              protocol >= 2025-06-18 and NOTHING at all for older revisions
#              (since IMP-b92421fb7c59). Either way the value is chosen per
#              FAMILY, never per verb.
#            * ActionCable `describe_tool` — serves the registered manifest,
#              whose `outputSchema` is `default_output_schema`
#              (mcp_platform_tool_registrar.rb `default_output_schema`, from
#              `build_manifest`): one shared literal for all 606. Since
#              IMP-e809396f9eda (2026-09-02) that literal is
#              `{success, error, data}` where `data` carries the
#              pending-approval envelope — still verb-independent, still not
#              a per-action declaration.
#
#          This is not a parsing problem — the thing being compared against
#          does not exist. The tripwire below pins the declaration side and the
#          ActionCable manifest. It deliberately does NOT pin
#          `decorate_tool_entry`: its `output_schema:` is chosen per family by
#          the caller, not derived from the tool, so it is verb-independent by
#          construction rather than by coincidence, and
#          pinning three lines that would have to be rewritten to do damage
#          buys less than it costs. Named here so the omission reads as a
#          decision.
#       2. THE DOCS' OWN CLAIM IS DELIBERATELY PARTIAL. 50 of the 65 return
#          key-sets in the covered corpus (COVERED_DOCS *and* the one
#          COVERED_CALLS file) carry a `...` elision. For those an
#          EQUALITY oracle is not merely hard, it is WRONG — the doc asserts
#          a subset on purpose. Containment is all that is left, and
#          containment cannot see a MISSING key.
#       3. HALF THE DOCUMENTED KEYS ARE NESTED, AND THEIR PRODUCER IS NOT
#          LOCAL. 105 of 207 documented return keys sit below the top level.
#          They come from `to_summary` on a model, from `serialize_instance`,
#          or from a service's hash bound to a local — `drain_result: result`
#          in system_fleet_tool.rb, whose three keys live in
#          instance_pool_service.rb:346. Reaching them needs interprocedural
#          analysis across model and service files.
#       4. THE ROOT OF A `// →` COMMENT IS ITSELF UNDECLARED. `success_result`
#          wraps as `{success:, data:}` (base_tool.rb:467). 64 of the 65 sites
#          document the `data` payload; disk-image-ci.md:57 documents the full
#          envelope. Nothing marks which, so a parser must GUESS the depth its
#          comparison starts at.
#       5. HANDLER RESOLUTION IS PARTIAL ANYWAY. Of the 54 verbs with a
#          key-set return comment, 31 have a single literal-hash
#          `success_result`; 10 have several (one `// →` cannot be equality-
#          checked against N key sets), 9 have none in the dispatched method,
#          2 pass a non-literal, 2 do not resolve through the `when ... then`
#          dispatch at all.
#
#     Net: two independent ~50% cuts (top-level keys; verbs with a resolvable
#     single literal) leave a handler-source oracle adjudicating on the order
#     of a quarter of documented return keys — containment-only on three
#     quarters of THOSE. The two fractions were measured over different
#     populations, so treat the product as a magnitude, not a figure. Either
#     one alone already settles it: that is a materially WEAKER instrument
#     than the parameter gate, not a return-side equivalent of it, and
#     building it would invite exactly the misreading that this file covers
#     returns.
#
#     Measured, not argued (2026-08-31, at the commit that wrote this header):
#     with `claim_id` and `host_address` planted in instance-pool-tuning.md's
#     acquire return comment — two keys the SAME FILE's withdrawal table says
#     are not returned — this spec ran 826 examples, 0 failures. Nothing
#     re-runs that experiment, so it is dated on purpose; the tripwire below,
#     which does re-run, is what carries the claim forward.
#
#     Prior drift filed separately and still open: 02-first-module.md and
#     module-authoring.md both document version fields the serializer does not
#     emit.
#   * Whether the values are MEANINGFUL. Since IMP-389daefb3ab4 a value's
#     SHAPE is checked against the declared type — an object where a scalar is
#     declared is the "nested it under an extra key" mistake — but nothing
#     reads the value itself, and the keys INSIDE an object literal are still
#     unchecked, because no tool declares a nested schema to check them
#     against. See shape_mismatches.
#   * Prose mentions of a verb with no call site, and — for the PARAMETER
#     checks only — docs outside COVERED_DOCS/COVERED_CALLS. Verb EXISTENCE is
#     swept tree-wide and ungated; see the sweep at the bottom of this file for
#     why the two are deliberately asymmetric.

# Namespaced rather than left on Object: these are generic names, and a bare
# COVERED_DOCS/KNOWN_BROKEN inside a describe block lands as a top-level
# constant that another spec can clobber (an order-dependent "already
# initialized constant" flake).
module ModuleDocsMcpCallSignatures
  # Every doc whose `platform.<verb>({ ... })` examples are known to match the
  # verbs' declared parameters. Widening this list is the acceptance signal for
  # IMP-84c318bf31f9: a file enters only once every call site in it passes.
  #
  # Scope note (IMP-84c318bf31f9, measured 2026-08-30): 31 docs under
  # extensions/system/docs contain a platform call. Pointing this same parser at
  # all 31 reports 207 failing examples in 24 of them; 3 of those failures are
  # the two KNOWN_BROKEN sites below, so 204 across 23 files remain to drain.
  # It is drained in reviewable batches rather than one mass edit — 31 operator
  # docs changed in a single unreviewed commit is the bulk-change hazard the
  # repo's own guardrails call out. Add files here as batches land.
  #
  # BATCH 0 — files that already passed the tree-wide sweep with no edit. They
  # are listed to stop a future edit regressing them, not because anything was
  # fixed in them.
  COVERED_DOCS = [
    "docs/CLAUDE_TMUX_MODULE.md",
    "docs/SDWAN_ARCHITECTURE.md",
    "docs/runbooks/acme-issuance.md",
    "docs/runbooks/module-authoring.md",
    "docs/runbooks/template-authoring.md",
    "docs/runbooks/vault-credential-restoration.md",
    "docs/tutorials/02-first-module.md",
    "docs/tutorials/06-rolling-upgrade.md",
    # BATCH 4 — system_set_default_disk_image_publication declares only
    # publication_id; five sites also passed node_platform_id, which the
    # executor never reads (it derives the platform from the publication,
    # system_fleet_tool.rb:5446) and which nothing rejects. disk-image-ci.md
    # keeps one KNOWN_BROKEN recent_events call, below.
    "docs/DISK_IMAGE_MANAGER_AGENT.md",
    "docs/runbooks/disk-image-ci.md",
    # BATCH 3 — no doc edit: its only failure was a `// ...same inputs...`
    # elision, which the required-parameter check now correctly exempts. It is
    # here so the exemption itself has live coverage in this spec.
    "docs/runbooks/expose-service.md",
    # BATCH 1 — the bare `id:` rename family. 24 call sites across 14 files
    # passed a resource id under the key `id` where the verb declares
    # `<resource>_id`; the values were already ids, so it was a pure key
    # rename. Only these two files became fully clean as a result.
    "docs/runbooks/storage-migration.md",
    "docs/tutorials/13-expose-service-tls.md",
    # IMP-d40df31d9cef — the whole GitOps tutorial, every call site. Its
    # troubleshooting section prescribed platform.list_vault_credentials, a verb
    # in NEITHER registry, as the only diagnostic it offered for a failing sync;
    # a tree-wide sweep with this parser confirms it was the sole unlabelled
    # nonexistent verb under docs/. The others were the sensor-config pair in
    # FLEET_SENSORS.md, which the surrounding prose marked "aspirational";
    # IMP-ca485128072e implemented both, so ASPIRATIONAL_VERBS is now empty.
    #
    # That gap is now closed at the root: IMP-2a5a9a0fed0a moved verb existence
    # OUT of this per-file allowlist and into the tree-wide sweep at the bottom
    # of this file, so a nonexistent verb reddens wherever it is written and
    # entering COVERED_DOCS is no longer what buys that check.
    "docs/tutorials/10-gitops-fleet.md",
    # IMP-ebc1d180dc10 — two silently-dropped keys, both withdrawn in the doc
    # rather than deleted. system_acquire_pooled_instance declares only
    # pool_name/pool_id/lifecycle_class; :72 also passed acquired_by and
    # acquired_for under a comment promising they were "stamped on the claim
    # record" (acquire! writes exactly pool_state + pool_acquired_at, and
    # there is no claim record other than the instance row). :107 passed
    # pool_id to system_return_pooled_instance, which declares only
    # instance_id. Those were the file's ONLY two failing sites — its other
    # six call sites already passed — so it graduates straight to COVERED_DOCS
    # and gets whole-file coverage rather than a per-verb COVERED_CALLS entry.
    # The withdrawal note added a 9th site: the system_lease_ci_runner call in
    # the Phase 2 blockquote, which the parser matches inside prose and which
    # this file therefore now checks too.
    #
    # RETIRED by IMP-4081ea184746. Was: "Known gap, measured: COVERED_DOCS has
    # no per-verb existence pin, so DELETING the corrected acquire example
    # passes green (346 -> 343 examples, 0 failures) — only the example count
    # moves." It did, and it was still true at 658 -> 655 the day it was fixed.
    # COVERED_DOC_CALL_SITES now pins every site in every covered file, so
    # deleting that example reddens naming the verb. Its per-SITE multiset is
    # what closes the case COVERED_CALLS' existence guard could not: this file
    # is 9 sites over 9 distinct verbs, which is the only reason a per-verb pin
    # would have caught the acquire deletion at all.
    "docs/runbooks/instance-pool-tuning.md",
    # IMP-1abe2148b0f3 — 8 failing call sites, 16 examples. Five were
    # mechanical (system_create_node declares name/template_id, not
    # hostname/node_template_id, and no metadata; system_provision_instance's
    # two required provider ids; system_create_template's required
    # node_platform_id; system_sdwan_create_firewall_rule's
    # firewall_action/src_selector/dst_selector/port_from/port_to/name, whose
    # `{ kind: "vip" }` selector is not one of the four
    # Sdwan::FirewallRule::SELECTOR_KINDS either). Three were not: Steps 3-4
    # were built on re-templating a PROVISIONED instance, which no MCP verb
    # does. system_update_node declares node_template_id and writes it, but the
    # only thing that materializes NodeModuleAssignment rows FROM A TEMPLATE'S
    # CLOSURE is System::TemplateApplyService (other services create assignment
    # rows directly — InferenceDeploymentService:114, FlowExporterDeployer:147,
    # ModuleCommitService:493 — none of them from a template). Its callers are
    # ProvisioningService#apply_node_template, FulfillmentAdvanceOrchestrator,
    # the autonomous Fleet::DecisionEngine arm and
    # POST /api/v1/system/nodes/:id/apply_template. Exactly one is MCP-reachable
    # — system_provision_instance, and only while provisioning — so no MCP verb
    # applies a template to an ALREADY-PROVISIONED node, and
    # Runtime::SyncModules reads node.node_module_assignments, not the
    # template. Those two calls are withdrawn in the doc (kept visible with a
    # what-is-actually-true table, per instance-pool-tuning.md) rather than
    # corrected, so the file is fully clean and takes whole-file coverage.
    # The fictional recent_events({ kind_prefix: "system.k3s" }) poll for a
    # cluster.bootstrapped event that nothing emits was replaced by prose
    # naming the real observable — the same treatment that RETIRED the
    # system_drift_report KNOWN_BROKEN entry below, and the reason this file
    # needs no new exclusion.
    "docs/tutorials/05-multi-cluster-k3s.md"
  ].freeze

  # Every call site each COVERED_DOCS file must go on documenting
  # (IMP-4081ea184746) — one token per SITE, not per verb.
  #
  # COVERED_DOCS buys a file the unknown-key and required-parameter checks, and
  # those checks are generated PER CALL SITE. Delete the call site and the
  # examples it generated simply stop existing: measured on this tree, deleting
  # the corrected system_acquire_pooled_instance example from
  # instance-pool-tuning.md took the suite from 658 examples to 655 with ZERO
  # failures. Nothing reddened when an edit removed the very call a finding was
  # closed by correcting — the one regression the opt-in exists to prevent.
  #
  # COVERED_CALLS' per-verb `documents at least one platform.<verb> call` guard
  # is the right shape but the wrong scope twice over. It pins only the verbs
  # it lists, so reusing it here would have covered the acquire site and
  # dropped the other eight in that file. And it pins EXISTENCE, so it cannot
  # see the deletion of one site among several calling the same verb — which
  # is 33 of this set's 142 sites, including both corrected
  # system_provision_instance calls in 05-multi-cluster-k3s.md and the single
  # elided call in expose-service.md that is the only live coverage of
  # elides_arguments? anywhere in this spec. Hence a MULTISET: the count of
  # tokens per verb is the count of sites the file must keep.
  #
  # A no-arg site is written `verb()`, and is a DIFFERENT token from `verb`.
  # It has to be, because the shapes are not interchangeable here: a no-arg
  # site generates no unknown-key and no required-parameter example at all, so
  # rewriting `platform.verb({ ... })` to `platform.verb()` deletes both checks
  # while leaving the verb documented. Distinct tokens make that rewrite redden
  # like any other deletion. Five verbs in this set are no-arg only.
  #
  # A FLOOR, not an equality: the file must still carry at least these sites,
  # and may carry more. Adding a call site is ordinary doc work and should not
  # need a spec edit — IMP-84c318bf31f9's drain is still landing corrected
  # sites in these files. The cost is real and is stated rather than hidden:
  # sites added from here on are unpinned until someone extends this list, so
  # a batch that adds sites should extend it in the same commit. Equality would
  # cost nothing today (this list is exact as of 2026-08-31) and was rejected
  # only because it taxes every future doc addition.
  COVERED_DOC_CALL_SITES = {
    "docs/CLAUDE_TMUX_MODULE.md" => %w[
      system_assign_module_to_template
    ],
    "docs/SDWAN_ARCHITECTURE.md" => %w[
      system_sdwan_compile_ovn_plan system_sdwan_compile_route_policy system_sdwan_get_bgp_config_for_peer
    ],
    "docs/runbooks/acme-issuance.md" => %w[
      system_acme_create_dns_credential system_acme_get_certificate system_acme_provision_certificate
      system_acme_provision_certificate system_acme_renew_certificate system_acme_revoke_certificate
    ],
    "docs/runbooks/module-authoring.md" => %w[
      system_assign_module_to_template system_list_module_versions system_promote_module_version
      system_promote_module_version system_promote_module_version system_validate_module_manifest
    ],
    "docs/runbooks/template-authoring.md" => %w[
      system_assign_module_to_template system_compose_preview_template system_create_template
      system_update_template_module
    ],
    "docs/runbooks/vault-credential-restoration.md" => %w[
      create_learning system_rotate_vault_transit_pepper
    ],
    "docs/tutorials/02-first-module.md" => %w[
      list_gitea_workflow_runs system_assign_module_to_template system_create_node
      system_delete_module system_drift_report system_get_instance
      system_list_module_versions system_promote_module_version system_promote_module_version
      system_promote_module_version system_provision_instance system_terminate_instance
      system_unassign_module_from_template system_validate_module_manifest
    ],
    "docs/tutorials/06-rolling-upgrade.md" => %w[
      agent_introspect create_learning list_agents()
      recent_events system_get_instance system_get_instance
      system_list_instances system_list_module_versions system_list_module_versions
      system_platform_maintenance system_refresh_instance_modules system_rollback_module_version
      system_rollback_module_version
    ],
    "docs/DISK_IMAGE_MANAGER_AGENT.md" => %w[
      system_list_disk_image_publications system_set_default_disk_image_publication
    ],
    "docs/runbooks/disk-image-ci.md" => %w[
      dispatch_gitea_workflow get_gitea_job_logs get_gitea_workflow_run
      provision_disk_image_webhook recent_events system_list_ci_workers()
      system_list_disk_image_publications system_list_disk_image_webhooks() system_provision_ci_worker
      system_set_default_disk_image_publication system_set_default_disk_image_publication system_set_disk_image_retention
      system_terminate_ci_worker
    ],
    "docs/runbooks/expose-service.md" => %w[
      system_expose_service_publicly system_expose_service_publicly system_expose_service_publicly
    ],
    "docs/runbooks/storage-migration.md" => %w[
      system_approve_storage_migration system_cancel_storage_migration system_cleanup_storage_migration
      system_cleanup_storage_migration system_get_instance system_get_storage_migration
      system_get_volume system_get_volume system_list_storage_assignments_by_owner
      system_list_storage_migrations system_migrate_storage_component system_report_storage_migration_progress
      system_report_storage_migration_progress system_report_storage_migration_progress system_report_storage_migration_progress
      system_report_storage_migration_progress system_report_storage_migration_progress system_revert_storage_migration_binding
      system_storage_chown_retry system_storage_chown_retry system_storage_chown_status
      system_test_nfs_export
    ],
    "docs/tutorials/13-expose-service-tls.md" => %w[
      system_expose_service_publicly system_sdwan_delete_port_mapping system_sdwan_delete_virtual_ip
      system_sdwan_list_networks() system_sdwan_list_peers
    ],
    "docs/tutorials/10-gitops-fleet.md" => %w[
      create_gitea_repository system_delete_node system_gitops_apply_proposal
      system_gitops_get_drift_report system_gitops_get_repository system_gitops_get_sync_run
      system_gitops_get_sync_run system_gitops_list_repositories system_gitops_register_repository
      system_gitops_sync_repository
    ],
    "docs/runbooks/instance-pool-tuning.md" => %w[
      system_acquire_pooled_instance system_create_instance_pool system_delete_instance_pool
      system_drain_instance_pool system_get_instance system_get_instance_pool
      system_lease_ci_runner system_return_pooled_instance system_terminate_instance
    ],
    "docs/tutorials/05-multi-cluster-k3s.md" => %w[
      kubernetes_decommission_cluster kubernetes_get_kubeconfig kubernetes_get_kubeconfig
      kubernetes_list_clusters() kubernetes_list_clusters() kubernetes_list_clusters()
      kubernetes_list_nodes kubernetes_list_nodes system_assign_module_to_template
      system_assign_module_to_template system_create_node system_create_node
      system_create_template system_create_template system_delete_template
      system_delete_template system_provision_instance system_provision_instance
      system_sdwan_attach_peer system_sdwan_attach_peer system_sdwan_create_firewall_rule
      system_sdwan_create_firewall_rule system_sdwan_create_network system_sdwan_delete_network
      system_sdwan_get_routing_summary system_sdwan_get_routing_summary system_terminate_instance
      system_terminate_instance system_update_template_module
    ]
  }.freeze

  # Docs NOT in COVERED_DOCS, pinned one VERB at a time.
  #
  # COVERED_DOCS is all-or-nothing per file: a doc enters only once every call
  # site in it passes. That leaves a corrected call site in an otherwise-unclean
  # file with no coverage at all, so nothing reddens when a later edit
  # reintroduces the exact defect that was just fixed. This list closes that gap
  # without pretending the rest of the file is clean — the listed verbs get the
  # full unknown-key and required-parameter checks, every other call in the file
  # is still unchecked and still owed to IMP-84c318bf31f9's drain.
  #
  # A file must not appear in both lists (asserted below); when it graduates to
  # COVERED_DOCS, delete its entry here.
  COVERED_CALLS = {
    # IMP-17926b4740a8 — the Phase 1 create example passed seven keys
    # (account_id, hostname, node_template_id, node_platform_id,
    # node_architecture_id, lifecycle_class, metadata), NONE of which
    # system_create_node declares, and neither required parameter. The rest of
    # this runbook's call sites (system_get_task({ id: }), list_agents,
    # execute_agent, ...) are the rename family and stay uncovered for now.
    # IMP-b4d9d7908c48 — the Phase 5 drain example passed `cordon_only: false`
    # under the comment "false → also stop services after cordon".
    # system_drain_instance declares exactly `instance_id`; `cordon_only` is
    # undeclared, and BaseTool#validate_params! only checks that REQUIRED keys
    # are present — it never rejects an extra one, so the key was silently
    # dropped. The pin is on the verb, not the key, so a future doc edit that
    # reintroduces any undeclared parameter on this call reddens.
    #
    # IMP-f4fe1ed1ec1e — this rationale used to add "and timeout_seconds" and
    # to describe the handler as merging two config keys and emitting a
    # FleetEvent, citing line ranges. Both halves are now false: the timeout
    # was dropped with the markers it belonged to, and the handler delegates
    # to System::Ai::Skills::PlatformResilienceExecutor, which cordons the pool
    # member and stops the instance. Line numbers are deliberately gone from
    # this note — a citation that rots silently is how the stale claim above
    # survived a rewrite of the code it described.
    "docs/runbooks/node-provisioning.md" => %w[system_create_node system_drain_instance]
  }.freeze

  # Call sites left BROKEN on purpose, each tracked by a filed finding, because
  # the verb cannot do what the surrounding prose says it does — correcting the
  # parameter names would make a fictional example look verified.
  #
  # Asserted STILL BROKEN rather than skipped, so the exclusion retires itself:
  # fixing the underlying finding reddens the example and forces its removal.
  KNOWN_BROKEN = {
    # 01a05174-974f-7968-9cf3-e665f42fdf17 — recent_events declares only
    # source_type/status/limit, emits no `kind` field, and NOTHING in the repo
    # emits the module.upgrade.* events this step tells an operator to poll for
    # (RollingModuleUpgradeExecutor is plan-only and has no emitter).
    ["docs/tutorials/06-rolling-upgrade.md", "recent_events"] => %w[kind_prefix],
    # Same finding, second call site (IMP-84c318bf31f9 batch 4): the
    # troubleshooting table tells an operator to poll
    # system.disk_image_publish_failed through a `kind_prefix` recent_events
    # does not declare.
    ["docs/runbooks/disk-image-ci.md", "recent_events"] => %w[kind_prefix]
    # RETIRED by IMP-e8dc40813adb (this spec's own instruction: the entry
    # matched no call site once the example was removed).
    #
    # Was: 01a05174-e4c3-71c2-b89d-111ef3328576 —
    # ["docs/tutorials/06-rolling-upgrade.md", "system_drift_report"] => %w[template_id]
    #
    # system_drift_report is still per-instance only. What changed first is
    # that 06-rolling-upgrade.md's Verification section no longer MAKES the
    # template-scoped call — rewriting it (its premise, "after all batches
    # complete", was false) replaced the fictional call with prose stating the
    # per-instance limit outright. IMP-0d106a152c47 then closed the other half:
    # system_platform_maintenance({ op: "drift_check" }) was a hardcoded stub
    # and is now wired to NodeInstance#module_drift, so that section documents
    # it as the deployment-scoped answer. Other files may still carry the
    # template_id call shape (docs/runbooks/cve-response.md did).
  }.freeze

  # Call sites exempted from the TREE-WIDE verb-existence sweep below, keyed
  # [relative_path, verb]. Adding a line here is a POLICY CLAIM, not
  # housekeeping: it asserts that this doc names a verb the platform does not
  # implement, on purpose, and that the surrounding prose says so. State the
  # rationale, the way KNOWN_BROKEN and the writer-set ratchets do — an
  # unexplained exemption is indistinguishable from a defect six months on.
  #
  # Self-retiring, like KNOWN_BROKEN: each entry is asserted STILL
  # UNREGISTERED. Implementing the verb reddens its exemption and forces the
  # entry's removal, so the list cannot rot into permanent suppression.
  #
  # The exemption is per VERB, not per file: every OTHER call in an exempted
  # file is still swept. It buys silence for one named fiction, not a blanket
  # pass for the doc that carries it.
  #
  # An entry takes effect ONLY on a call site that is COMMENTED OUT
  # (IMP-6f2ebf01424a). Every rationale here must argue about a commented-out
  # example; none can be an argument for exempting a live one: a live
  # call to a verb no registry implements PRESCRIBES the fiction rather than
  # describing it, and an operator copying it cannot run it at all. Adding an
  # entry for a live call site does not silence the sweep — it adds a second
  # failure. See aspirational_exemption?.
  #
  # docs/.verify/ASPIRATIONAL_MCP.md is the operator-facing view of this list,
  # DERIVED from it and pinned by the equality oracle below — no longer a
  # second hand-maintained register, and no longer kept in step by hand.
  #
  # It used to be. The paragraph that stood here argued the catalog
  # "legitimately stays EMPTY while both entries here are `//`-framed, because
  # the script's comment filter cannot see them", and that an entry was owed
  # only for a site the script CAN see. The reasoning was sound about the
  # script as it then behaved and wrong about what the catalog is for: the
  # script skipped `//`, `#` and `>` lines, so its silence was a property of
  # its own filter, not evidence about the corpus — and ASPIRATIONAL_MCP.md
  # went on to cite that silence as proof it was empty. IMP-2b09c9f22bae
  # removed the filter (measured: the dropped lines carried 9 prefixed verbs,
  # only 4 of them invisible anywhere else, of which 2 were registered and 2
  # were the sensor-config pair then listed below — no new unknowns) and gave
  # the script a catalogued-vs-unknown split, so it SAW both sites and resolved
  # them through the catalog. That pair is now registered too (IMP-ca485128072e),
  # so the catalog is empty and the script has nothing left to resolve.
  #
  # The two checkers still do not contain one another, so do not treat one
  # green as covering the other's ground. This sweep reads bare verbs the
  # script's prefix filter drops (recent_events, execute_agent, list_agents);
  # the script in turn matches a reference wherever it appears, so it is not
  # bounded by this parser's brace balancing. What has changed is that the
  # aspirational REGISTER is now single-sourced here: add an entry to this
  # hash, and the oracle below tells you what the markdown must say.
  # EMPTY as of IMP-ca485128072e (APO-2e), and reached the way the note below
  # says it must be: by DELETING entries, each of which reddened its own
  # self-retiring guard first. The pair that lived here —
  # system_get_sensor_config / system_update_sensor_config, both in
  # FLEET_SENSORS.md's "Configuring Sensor Thresholds" section — was
  # implemented rather than re-argued. Both verbs are now registered in
  # Ai::Tools::PlatformApiToolRegistry::TOOLS and backed by
  # System::Fleet::SensorConfig, so their doc examples are LIVE calls and are
  # checked like any other.
  #
  # Do not repopulate this to silence a red sweep. An entry is a claim that the
  # PLATFORM does not implement a verb the doc describes; the remedies for a
  # failing call site are, in order: fix the spelling, implement the verb, or
  # withdraw the example. An entry is only for a doc that deliberately
  # describes a capability that does not exist yet, and it exempts a
  # COMMENTED-OUT site alone (see aspirational_exemption?).
  ASPIRATIONAL_VERBS = {}.freeze

  # ── ASPIRATIONAL_MCP.md is DERIVED from this list, not restated beside it ──
  #
  # IMP-2b09c9f22bae. docs/.verify/ASPIRATIONAL_MCP.md is the operator-facing
  # register of the same fact ASPIRATIONAL_VERBS holds: which documented verbs
  # the platform does not implement. Until now it was a hand-maintained second
  # copy, and it had drifted to the worst possible value — it declared the
  # catalog EMPTY and cited a clean check-mcp-actions.sh run as the proof,
  # while the harness it cited filters out `//` lines and so cannot see either
  # of the two entries below. A control whose own report suppressed the audit
  # that would have found the gap.
  #
  # The fix is a single source of truth with the other copies PINNED to it, not
  # three artefacts agreeing by convention. ASPIRATIONAL_VERBS is that source
  # because it is the only one already staleness-guarded from BOTH sides:
  # "is still unimplemented, as its exemption claims" retires an entry the day
  # the verb is registered, and "exercises every ASPIRATIONAL_VERBS exemption"
  # retires one whose call site is deleted. Neither guard reads the markdown
  # file or the shell script, so this oracle does not close a loop: the
  # markdown derives from the constant, and the constant answers to the
  # registry and the docs corpus.
  #
  # Deliberately NOT the reverse direction. Deriving the constant from the
  # markdown would put the policy record in a file nothing type-checks, and
  # deriving the markdown from the SHELL SCRIPT'S OUTPUT — the tempting
  # shortcut — would reproduce the original defect exactly: the script cannot
  # see a commented-out site, so a catalog built from its output is empty by
  # construction and agrees with the script no matter how wrong both are.
  #
  # ANTI-VACUITY. An equality oracle between two sets is vacuous when both go
  # empty, which is precisely the state this task found. Three separate pins,
  # because the failure mode here is a parser that silently returns nothing:
  #
  #   1. the BEGIN/END markers must EXIST in the file — a renamed or deleted
  #      region is a failure, not an empty catalog;
  #   2. the delimited region must contain at least one table ROW whenever
  #      ASPIRATIONAL_VERBS is non-empty — a marker pair around prose parses
  #      to nothing and would otherwise pass the moment the constant emptied;
  #   3. equality is asserted on [doc, verb] PAIRS both ways, so a row naming
  #      the right verb against the wrong doc fails.
  #
  # When the fiction is finally implemented and ASPIRATIONAL_VERBS empties for
  # real, pin 2 relaxes with it and the markdown is expected to carry no rows.
  # That end state is reached by DELETING entries here, which reddens their
  # own self-retiring guards first — it cannot be reached by the catalog
  # quietly going blank, which is the way it went wrong before.
  ASPIRATIONAL_CATALOG_PATH = "docs/.verify/ASPIRATIONAL_MCP.md"
  ASPIRATIONAL_CATALOG_BEGIN = "<!-- ASPIRATIONAL-CATALOG:BEGIN -->"
  ASPIRATIONAL_CATALOG_END = "<!-- ASPIRATIONAL-CATALOG:END -->"

  # Parses the delimited catalog region into [[doc, verb], ...].
  #
  # Rows are read as `| `verb` | `doc` | ... |` with both cells BACKTICKED, and
  # the header/separator rows are dropped by requiring backticks rather than by
  # counting lines. Backticks are load-bearing twice over: they are what makes
  # a row distinguishable from the surrounding prose, and writing the verb bare
  # (no `platform.` prefix) is what keeps this catalog from being read as a
  # CALL SITE by the tree-wide sweep above and by check-mcp-actions.sh, both of
  # which glob docs/.verify/ along with everything else. A catalog that
  # registered as a call site would flag its own rows as unknown verbs.
  def self.parse_aspirational_catalog(text)
    region = text[/#{Regexp.escape(ASPIRATIONAL_CATALOG_BEGIN)}(.*?)#{Regexp.escape(ASPIRATIONAL_CATALOG_END)}/m, 1]
    return nil if region.nil?

    rows = region.lines.filter_map do |line|
      # lstrip so an indented row is read the way the shell's
      # `^[[:space:]]*\|` reads it; otherwise an indented row would be
      # invisible here and visible there, and the two readers would disagree.
      next unless line.lstrip.start_with?("|")

      cells = line.split("|").map(&:strip)
      verb = cells[1].to_s[/\A`([a-z][a-z0-9_]+)`\z/, 1]
      doc = cells[2].to_s[/\A`([^`]+)`\z/, 1]
      [ doc, verb ] if verb && doc
    end

    rows
  end
end

RSpec.describe "module docs: MCP worked examples vs. declared tool parameters" do
  ext_root = File.expand_path("../../..", __dir__)
  covered_docs = ModuleDocsMcpCallSignatures::COVERED_DOCS
  covered_calls = ModuleDocsMcpCallSignatures::COVERED_CALLS
  covered_doc_sites = ModuleDocsMcpCallSignatures::COVERED_DOC_CALL_SITES

  # Extract `platform.<verb>({ ... })` calls, returning
  # [verb, top_level_entries, line_number, elides_arguments?, commented_out?],
  # where top_level_entries is [[key, value_shape], ...].
  # Brace/bracket depth aware, string aware, and skips `//`
  # comments INSIDE an argument literal, so a nested `options: { ... }`
  # contributes only `options` and a `// → { ... }` response comment is not
  # mistaken for an argument.
  #
  # A call written on a `//` comment LINE is still extracted and checked,
  # however many lines its argument literal spans — provided the `//` STARTS
  # each line, after whitespace only. A commented-out call framed some other
  # way (blockquoted `> //`, list-indented `- //`, or with a blank line
  # breaking the run) is still dropped; see comment_framed?. That is
  # deliberate: a
  # commented-out example is one an operator copies just the same, so it should
  # be as correct as a live one. It also means commenting a call out does not
  # silence this spec — the `documents at least one MCP call` guard below is
  # what catches a doc edit that drops every call and would otherwise make this
  # whole file pass vacuously.
  #
  # The multi-line half of that claim was FALSE until IMP-f97c629e59d7: a
  # closing brace on a subsequent `//` line was skipped as a comment, so the
  # literal never balanced and the call was dropped. See balanced_body.
  def self.extract_calls(text)
    calls = []
    text.to_enum(:scan, /platform\.([a-z0-9_]+)\(\s*\{/).each do
      verb = Regexp.last_match(1)
      open_brace = Regexp.last_match.end(0) - 1
      start = Regexp.last_match.begin(0)
      line = text[0...start].count("\n") + 1
      body = balanced_body(text, open_brace)
      next if body.nil?

      # Framing is read at the VERB, not at the `{`, so `commented` describes
      # the same line as `line` — the two differ for `platform.foo(\n  { ... }`
      # — and matches extract_noarg_calls, which has always read it there.
      # balanced_body still starts at the brace; only this flag moves. No doc
      # writes that shape today, so reading it at the brace instead is an
      # equivalent mutant: a convention fix, not a behaviour fix.
      calls << [ verb, top_level_entries(body), line, elides_arguments?(body),
                 comment_framed?(text, start) ]
    end
    calls
  end

  # Extract NO-ARGUMENT calls — `platform.<verb>()` — returning
  # [verb, line, commented_out?].
  #
  # Kept separate from extract_calls, which requires an opening `{` because
  # everything it exists to check is a property of the argument literal. A
  # no-arg call has no keys to check and no required parameters to compare
  # against, so it is invisible to the parameter families by construction and
  # correctly so. But it still NAMES A VERB, and a fictional verb is just as
  # uncallable with no arguments as with some — so the tree-wide existence
  # sweep consumes this too. Measured 2026-08-31: 26 such sites across 12 docs,
  # 11 distinct verbs, every one of which resolves today; without this they
  # would be the one shape a "tree-wide" existence claim silently missed.
  #
  # Deliberately NOT folded into extract_calls: doing so would hand the
  # parameter checks a keyless call site in every COVERED_DOCS file, and the
  # required-parameter example would then fail on verbs that legitimately take
  # arguments the doc elided by writing `()`. That is the opt-in drain's
  # problem, not this sweep's.
  def self.extract_noarg_calls(text)
    calls = []
    text.to_enum(:scan, /platform\.([a-z0-9_]+)\(\s*\)/).each do
      verb = Regexp.last_match(1)
      start = Regexp.last_match.begin(0)
      line = text[0...start].count("\n") + 1
      calls << [ verb, line, comment_framed?(text, start) ]
    end
    calls
  end

  # Given the index of an opening `{`, return the text strictly inside its
  # matching `}`, or nil when the literal never closes (a truncated example).
  #
  # Two passes, because a `//` means two different things (IMP-f97c629e59d7).
  # Inside a LIVE example it introduces a comment, and skipping to end-of-line
  # is right. But when the whole example is COMMENTED OUT, the leading `//` on
  # each line is framing rather than a comment, and skipping past it swallows
  # any closing brace that shares a line with it — the literal then never
  # balances and the call is dropped silently, costing no example anywhere.
  # That was live: FLEET_SENSORS.md's system_update_sensor_config was invisible
  # to every family in this file, including the tree-wide existence sweep.
  #
  # So: scan the text as written first, and only if that fails AND the call is
  # comment-framed, retry against the de-framed region. A live truncated
  # example is unaffected — it fails the first pass and is not framed, so it is
  # still dropped rather than stitched to whatever follows.
  def self.balanced_body(text, open_index)
    body = scan_balanced(text, open_index)
    return body unless body.nil? && comment_framed?(text, open_index)

    scan_balanced(comment_framed_region(text, open_index), 0)
  end

  def self.scan_balanced(text, open_index)
    depth = 0
    i = open_index
    in_string = nil
    while i < text.length
      ch = text[i]
      if in_string
        i += 2 and next if ch == "\\"
        in_string = nil if ch == in_string
      elsif ch == '"' || ch == "'" || ch == "`"
        in_string = ch
      elsif ch == "/" && text[i + 1] == "/"
        i = text.index("\n", i) || text.length
        next
      elsif ch == "{" || ch == "["
        depth += 1
      elsif ch == "}" || ch == "]"
        depth -= 1
        return text[(open_index + 1)...i] if depth.zero?
      end
      i += 1
    end
    nil
  end

  # True when the call's own line is COMMENTED OUT — the line opens with `//`
  # before reaching the `{`. Deliberately anchored at the start of the line: a
  # `//` appearing mid-line (inside a URL string, say) is not framing, and
  # treating it as such would let the retry stitch a live truncated example to
  # unrelated comment lines below it.
  def self.comment_framed?(text, open_index)
    line_start = (text.rindex("\n", open_index) || -1) + 1
    text[line_start...open_index].match?(%r{\A[ \t]*//})
  end

  # The commented-out example, from its opening `{`, with the leading `//`
  # framing stripped from each continuation line.
  #
  # Bounded by the comment RUN: it ends at the first line that is not itself
  # framed, so the retry cannot reach past the block into prose, or into a
  # separate comment block further down, to manufacture a balance.
  #
  # Say what that does NOT buy, because the difference matters: prose written
  # INSIDE the same `//` run is de-framed along with everything else and then
  # parsed as code. A withdrawal note under a commented-out example — this
  # repo's keep-it-visible convention — carrying a stray `}` would close the
  # literal and contribute an English word as a key. Latent, not live: as of
  # IMP-ca485128072e, ZERO `//` runs in the tree contain a platform call —
  # `command grep -rn "//[[:space:]]*platform\." extensions/system/docs/`
  # returns only URL strings (DISK_IMAGE_CI.md and friends), no
  # `platform.<verb>(` site. The last one was FLEET_SENSORS.md's aspirational
  # sensor-config example, which that task made LIVE. The raw scan must also
  # have failed across the whole rest of the file for this to be reachable at
  # all.
  def self.comment_framed_region(text, open_index)
    line_end = text.index("\n", open_index) || text.length
    region = +text[open_index...line_end]
    (text[(line_end + 1)..] || "").each_line do |line|
      frame = line.match(%r{\A[ \t]*//[ \t]?})
      break if frame.nil?

      region << "\n" << line[frame.end(0)..].to_s.chomp
    end
    region
  end

  # The same scan, keeping each key's VALUE SHAPE — :object, :array, :scalar,
  # :elided (the value is `...`) or :shorthand (no `:` at all).
  #
  # The keys alone were all this parser kept (IMP-389daefb3ab4), so a doc could
  # write an object where the tool declares a string and nothing looked: the
  # key is present, so the required-parameter check passes, and the value is
  # never examined. Measured before this: nesting the REQUIRED node_platform_id
  # inside an object in template-authoring.md left the suite at 0 failures.
  #
  # Shape is as far as it goes, and the limit is not laziness. Checking nested
  # KEYS needs a nested declaration to check them against, and none exists.
  # Swept 2026-08-31 across every tool directory INCLUDING extensions/private:
  # 172 parameters declare `type: "object"`, and not one of them carries a
  # nested `properties:` — `object` is where every object declaration stops,
  # with the inner grammar (fleet_spec, reuse_check, recommends_override,
  # config) written only in the parameter's English description.
  #
  # The census is the weaker argument, though, and it is not absolute: nested
  # schemas are not wholly absent from the tree — trading_simulation_tool.rb
  # declares `items: { type: "string" }` on two ARRAY parameters, which is an
  # element type, not an object's keys, and so is no oracle for the
  # `config:`/`metadata:` nesting this finding is about.
  #
  # The structural argument this check was built on has EXPIRED: until
  # IMP-e809396f9eda (2026-09-02) MCP's schema synthesizer emitted only
  # `{"type", "description"}` per parameter, so a nested schema could never
  # reach the wire and a per-key nested check had nothing to compare against.
  # The synthesizer now carries `enum`, `items`, `default` and nested
  # `properties` through Ai::Tools::ParameterSchema (parameter_schema.rb,
  # called from mcp_platform_tool_registrar.rb#convert_to_json_schema and the
  # streamable-HTTP controller). So this top-level-only check is now the
  # WEAKER of the two possible oracles; widening it to nested keys is filed
  # as a follow-up (campaign-apo, "widen call-signature check to nested
  # schema keys") rather than done here, because that widening changes what
  # every covered doc is held to and deserves its own red-first run.
  def self.top_level_entries(body)
    keys = []
    depth = 0
    i = 0
    at_key_position = true
    in_string = nil
    while i < body.length
      ch = body[i]
      if in_string
        i += 2 and next if ch == "\\"
        in_string = nil if ch == in_string
      elsif ch == '"' || ch == "'" || ch == "`"
        in_string = ch
      elsif ch == "/" && body[i + 1] == "/"
        i = body.index("\n", i) || body.length
        next
      elsif ch == "{" || ch == "["
        depth += 1
      elsif ch == "}" || ch == "]"
        depth -= 1
      elsif depth.zero? && ch == ","
        at_key_position = true
      elsif depth.zero? && at_key_position && ch.match?(/[A-Za-z_]/)
        ident = body[i..].match(/\A[A-Za-z_][A-Za-z0-9_]*/)[0]
        keys << [ ident, value_shape(body, i + ident.length) ]
        at_key_position = false
        i += ident.length
        next
      elsif depth.zero? && !ch.match?(/\s/)
        at_key_position = false
      end
      i += 1
    end
    keys
  end

  # The shape of the value that follows a key, read from just past the
  # identifier. Comments between the `:` and the value are skipped, so
  # `config: // see below\n { ... }` still reads as an object.
  #
  # :shorthand means "no value to look at" — ES6 shorthand (`{ a, b }`), and
  # also a `key:` that runs out of body, which is the same thing for our
  # purposes since both are skipped. :elided is the `...` placeholder, and is
  # NOT elides_arguments?: that one asks whether the whole example elides
  # OTHER arguments, this one whether THIS value is written out. `k: .5` reads
  # as :elided on the leading dot — a misnomer, and harmless, because both are
  # skipped by shape_mismatches.
  def self.value_shape(body, after_ident)
    i = after_ident
    i += 1 while i < body.length && body[i].match?(/\s/)
    return :shorthand unless body[i] == ":"

    i += 1
    loop do
      i += 1 while i < body.length && body[i].match?(/\s/)
      break unless body[i] == "/" && body[i + 1] == "/"

      i = body.index("\n", i) || body.length
    end
    case body[i]
    when "{" then :object
    when "[" then :array
    when "." then :elided
    when nil then :shorthand
    else :scalar
    end
  end

  # True when the example deliberately ELIDES arguments: a bare `...`, or a `//`
  # comment containing `...`, standing where a KEY would go. Such an example
  # makes no claim about completeness, so the required-parameter check is not
  # applied to it — every key it DOES show is still checked.
  #
  # Measured for IMP-84c318bf31f9: 15 of the tree's call sites are elided this
  # way, and each was producing a "missing required" failure that is a parser
  # artefact rather than a doc defect. Nothing goes stale: the exemption is read
  # out of the file, so deleting the `...` restores the check on the next run.
  #
  # `{ node_id: ... }` is deliberately NOT this case. There the ellipsis is a
  # VALUE, and the example still asserts that node_id is the whole argument
  # list — which for system_provision_instance is false and does not work.
  def self.elides_arguments?(body)
    depth = 0
    i = 0
    at_key_position = true
    in_string = nil
    while i < body.length
      ch = body[i]
      if in_string
        i += 2 and next if ch == "\\"
        in_string = nil if ch == in_string
      elsif ch == '"' || ch == "'" || ch == "`"
        in_string = ch
      elsif ch == "/" && body[i + 1] == "/"
        line_end = body.index("\n", i) || body.length
        # The `...` must LEAD the comment. Merely containing one matches an
        # ordinary English ellipsis in a comment that happens to follow a
        # comma ("// waits, then... retries"), which would silently switch the
        # required-parameter check off for that call with no signal. All 15 of
        # the tree's real elisions lead with it ("// ... usual args ...").
        return true if depth.zero? && at_key_position && body[i...line_end].match?(%r{\A//\s*\.\.\.})

        i = line_end
        next
      elsif ch == "{" || ch == "["
        depth += 1
      elsif ch == "}" || ch == "]"
        depth -= 1
      elsif depth.zero? && ch == ","
        at_key_position = true
      elsif depth.zero? && at_key_position && body[i, 3] == "..."
        return true
      elsif depth.zero? && !ch.match?(/\s/)
        at_key_position = false
      end
      i += 1
    end
    false
  end

  # verb => { name => required? }, from the verb's OWN declaration.
  #
  # Two registries, because MCP has two. PlatformApiToolRegistry::TOOLS maps a
  # verb to a tool class exposing action_definitions; the introspection verbs
  # (platform.health, platform.recent_events, ...) are declared instead as JSON
  # Schema in McpToolRegistrar::INTROSPECTION_TOOLS and appear in NEITHER the
  # registry nor any action_definitions. Consulting only the first reports a
  # real verb as unregistered, which is how a genuinely wrong call
  # (recent_events with a kind_prefix it does not accept) gets misdiagnosed as
  # a spec gap and waved through.
  def self.declared_parameters(verb)
    from_tool_registry(verb) || from_introspection_registry(verb)
  end

  # verb => { name => declared type string }, from the same two registries.
  # Separate from declared_parameters because that one answers "is it
  # required?" and every caller of it wants exactly that; folding a second
  # question into its return value would ripple through four call sites for no
  # gain.
  def self.declared_types(verb)
    types_from_tool_registry(verb) || types_from_introspection_registry(verb)
  end

  # The "string" default matches MCP's own synthesizer
  # (mcp_platform_tool_registrar.rb:532), which is what an operator's client
  # actually receives for a parameter that omits :type. No parameter in the
  # tree omits it today, so dropping the default is an equivalent mutant —
  # verified, it survives — and the default is here for agreement with the
  # wire contract rather than for any live call site.
  def self.types_from_tool_registry(verb)
    klass_name = Ai::Tools::PlatformApiToolRegistry::TOOLS[verb]
    return nil if klass_name.nil?

    definition = klass_name.constantize.action_definitions[verb]
    return nil if definition.nil?

    (definition[:parameters] || {}).transform_keys(&:to_s)
                                   .transform_values { |spec| (spec[:type] || "string").to_s }
  end

  def self.types_from_introspection_registry(verb)
    tool = Ai::Introspection::McpToolRegistrar::INTROSPECTION_TOOLS
           .find { |t| t[:id] == "platform.#{verb}" }
    return nil if tool.nil?

    ((tool[:input_schema] || {})[:properties] || {}).transform_keys(&:to_s)
                                                    .transform_values { |spec| (spec[:type] || "string").to_s }
  end

  # Keys whose literal is the wrong SHAPE for the declared type, as
  # "<key>: declared <type>, got <shape>".
  #
  # Three rules, and the asymmetry between them is evidence-driven:
  #
  #   * declared `object` — the literal must be an object.
  #   * declared `array` — the literal must be an array.
  #   * declared anything else (a scalar type) — the literal must not be an
  #     OBJECT. An array is accepted.
  #
  # That last exception is not laxity, it is the tool declarations being
  # imprecise in a way this spec must not punish a doc for. system_create_module
  # and system_update_module declare mask/file_spec/package_spec/
  # dependency_spec/protected_spec as `type: "string"` and their descriptions
  # say "newline-joined globs OR ENCODED ARRAY" — and the model means it:
  # NodeModule#encode_spec returns a non-String attribute verbatim
  # (node_module.rb:654-655), so an Array is a correct value for a
  # string-declared parameter. Flagging it would tell the author of a correct
  # example that they had nested the value under an extra key. Since the
  # declaration cannot express string-or-array, this arm is dropped rather
  # than exempted one parameter at a time; tighten it if tools ever declare a
  # union. Nothing is lost against the finding this closes, which is about
  # values nested inside an OBJECT.
  #
  # Scalar TYPES are deliberately not compared to each other either:
  # `limit: 10` against `integer` and `id: "<uuid>"` against `string` are the
  # same check written twice, and docs write placeholders where real values go,
  # so string-vs-integer would flag prose. :shorthand and :elided values assert
  # nothing and are skipped.
  def self.shape_mismatches(entries, declared_types)
    entries.filter_map do |key, shape|
      declared = declared_types[key]
      next if declared.nil? || shape == :shorthand || shape == :elided

      case declared
      when "object" then "#{key}: declared object, got #{shape}" unless shape == :object
      when "array"  then "#{key}: declared array, got #{shape}" unless shape == :array
      else "#{key}: declared #{declared}, got object" if shape == :object
      end
    end
  end

  def self.from_tool_registry(verb)
    klass_name = Ai::Tools::PlatformApiToolRegistry::TOOLS[verb]
    return nil if klass_name.nil?

    definition = klass_name.constantize.action_definitions[verb]
    return nil if definition.nil?

    (definition[:parameters] || {}).transform_keys(&:to_s)
                                   .transform_values { |spec| spec[:required] == true }
  end

  def self.from_introspection_registry(verb)
    tool = Ai::Introspection::McpToolRegistrar::INTROSPECTION_TOOLS
           .find { |t| t[:id] == "platform.#{verb}" }
    return nil if tool.nil?

    schema   = tool[:input_schema] || {}
    required = (schema[:required] || []).map(&:to_s)
    (schema[:properties] || {}).keys.map(&:to_s)
                               .index_with { |name| required.include?(name) }
  end

  # Pinned call sites the file no longer documents, as "<token> (have N of M)".
  #
  # A MULTISET floor: a verb with three pinned sites needs three, and a file
  # that has GAINED a site is ordinary doc work and not a finding — see
  # COVERED_DOC_CALL_SITES.
  #
  # Keyword arguments on purpose, and be precise about what they buy. The
  # direction is unguarded at the CALL, not in the body: on a tree where the
  # pin is exact, binding the two the other way round inverts the policy to
  # "police sites the doc has ADDED, ignore ones it has deleted" and every
  # example in this file still passes — verified as a mutant, which survived.
  # Keywords make that swap self-announcing at the call site rather than
  # impossible; the fixture examples below pin this body's direction, not the
  # caller's binding. It stays unkillable while the pin is exact, because the
  # floor policy allows a doc to carry MORE than it pins and none does today.
  def self.missing_pinned_sites(pinned:, documented:)
    have = documented.tally
    pinned.tally.filter_map do |token, want|
      got = have.fetch(token, 0)
      "#{token} (have #{got} of #{want})" if got < want
    end
  end

  # Files opted into the parameter checks with no site pin, and pins naming a
  # file that is not opted in. Extracted so its direction is pinned on fixture
  # data: on a tree where the two lists agree, a mutant that compares either
  # list against itself passes every example generated from the real data.
  def self.pin_coverage_gaps(covered_docs, pinned_paths)
    [ covered_docs - pinned_paths, pinned_paths - covered_docs ]
  end

  # Pins that name a file but no sites. Extracted for the same reason: on a
  # tree where no entry is empty, a mutant that returns [] unconditionally
  # passes every example generated from the real data.
  def self.pins_without_sites(pins)
    pins.select { |_, sites| sites.empty? }.keys
  end

  # Call sites left BROKEN on purpose, each tracked by a filed finding, because
  # the verb cannot do what the surrounding prose says it does — correcting the
  # parameter names would make a fictional example look verified.
  #
  # These are asserted STILL BROKEN rather than skipped. A silent exclusion rots
  # into permanent suppression; this one retires itself, because fixing the
  # underlying finding reddens the example below and forces its removal.
  known_broken = ModuleDocsMcpCallSignatures::KNOWN_BROKEN
  exercised_exclusions = []

  # A whole-file target carries no verb filter; a COVERED_CALLS target carries
  # the verbs it pins and ignores every other call in that file.
  targets = covered_docs.map { |path| [ path, nil ] } +
            covered_calls.map { |path, verbs| [ path, verbs ] }

  # ── The RETURN-shape tripwire (IMP-ef37749c19f8) ───────────────────────────
  #
  # The header explains at length why this file cannot check documented RETURN
  # keys. Reason 1 — that there is no per-action return declaration to compare
  # against — is the only one of the five that could stop being true without
  # anyone noticing: it takes one `returns:` key on one definition, or one
  # per-tool outputSchema, and suddenly a real oracle exists and the header's
  # "NO" is stale prose that nothing contradicts.
  #
  # These two examples are that contradiction. They are not a substitute for
  # the check — nothing here reads a doc — and they must not be mistaken for
  # one. They assert, by EQUALITY rather than by "no key looks like a return
  # shape", that the oracle is still absent, so the day it appears this spec
  # reddens and points whoever added it at the analysis above.
  #
  # Equality is deliberate and it is why a new definition-level key reddens
  # even when it has nothing to do with returns. A containment form ("no key
  # named :returns") would pass on `output_schema:`, `emits:`, `result:` and
  # every other spelling, which is precisely the failure mode a tripwire
  # cannot afford. A spurious red here costs one reviewer one minute; a
  # silent green costs the next person the whole measurement.
  #
  # BOTH definition levels are read, and the second is not redundant. A
  # single-action tool's `action_definitions` is SYNTHESIZED from
  # `.definition` by BaseTool's default, which reconstructs the hash as
  # `{description:, parameters:}` and DISCARDS every other key
  # (base_tool.rb:17-21). A `returns:` written on such a tool's `.definition`
  # would therefore be invisible to the action-level assertion while still
  # being live — PlatformApiToolRegistry.tool_definitions merges
  # `klass.definition` verbatim for registry actions absent from
  # `action_definitions`. Reading `.definition` too closes that hole; found in
  # review, not by construction.
  describe "return-shape oracle (asserted ABSENT — see the header)" do
    # The same walk all three examples need. Deliberately NOT
    # McpPlatformToolRegistrar.tool_classes: that memoizes @tool_classes on the
    # class, and this file would be the first to populate a memo other specs
    # in the same process expect to be cold.
    #
    # `let`, and instance methods, rather than constants: a constant assigned
    # inside a block takes its cref from the enclosing LEXICAL scope, which for
    # a `describe` body is Object — so `ACTION_KEYS = ...` here would define a
    # generic top-level constant another spec can clobber. That is the same
    # order-dependent flake the module wrapper at the top of this file exists
    # to avoid; it applies in here too.
    let(:platform_tool_classes) do
      Ai::Tools::PlatformApiToolRegistry.all_tools.values.uniq.filter_map do |class_name|
        class_name.constantize
      rescue NameError
        nil
      end
    end

    let(:action_keys) { %i[description name parameters requires_approval].sort }
    let(:definition_keys) { %i[description name parameters].sort }

    it "declares no return shape on any ACTION, in any tool" do
      keys = platform_tool_classes.flat_map do |klass|
        next [] unless klass.respond_to?(:action_definitions)

        klass.action_definitions.values.flat_map(&:keys)
      end.uniq.sort

      expect(keys).to(
        eq(action_keys),
        "An action definition grew a key this spec has not seen: " \
        "#{(keys - action_keys).inspect}. If it declares a RETURN or OUTPUT " \
        "shape, the header's reason 1 is now false and a real return-key " \
        "oracle exists — re-read the five reasons and re-measure before " \
        "extending this file. If it is unrelated, add it to `action_keys`."
      )
    end

    # Not covered by the example above: see the BaseTool synthesis note.
    it "declares no return shape on any class-level .definition either" do
      keys = platform_tool_classes.flat_map do |klass|
        klass.respond_to?(:definition) ? klass.definition.keys : []
      rescue NotImplementedError
        []
      end.uniq.sort

      expect(keys).to(
        eq(definition_keys),
        "A tool's .definition grew a key this spec has not seen: " \
        "#{(keys - definition_keys).inspect}. BaseTool's default " \
        "action_definitions DISCARDS it (base_tool.rb:17-21), so the " \
        "action-level example above cannot see it — which is exactly why " \
        "this one exists. Same question: does it declare a RETURN shape?"
      )
    end

    # Scope, stated so it is not overread: this pins the ActionCable
    # `describe_tool` manifest only. The streamable-HTTP transport builds its
    # own entry and never reaches build_manifest — see the header's reason 1
    # for why that path is deliberately left unpinned.
    it "builds one verb-INDEPENDENT outputSchema into every registered manifest" do
      registrar = Ai::Tools::McpPlatformToolRegistrar
      schemas = platform_tool_classes.map do |klass|
        registrar.send(:build_manifest, klass)["outputSchema"]
      end.uniq

      expect(schemas).to(
        eq([ {
          "type" => "object",
          "properties" => {
            "success" => {
              "type" => "boolean",
              "description" => "False on refusal or failure; see `error`."
            },
            "error" => {
              "type" => "string",
              "description" => "Failure message. Present only when success is false."
            },
            # IMP-e809396f9eda (2026-09-02) added `data`, whose properties are
            # the pending-approval envelope every gated action can return. The
            # envelope's wire values are pinned by core's
            # spec/services/ai/tools/mcp_tool_schema_fidelity_spec.rb; this
            # oracle pins that the literal is still ONE shared, verb-independent
            # schema, so it names the constant rather than re-typing it.
            "data" => {
              "description" => "Action payload on success. For an approval-gated action " \
                               "parked by the autonomy gate it is the pending envelope below " \
                               "and NOTHING has been applied yet.",
              "additionalProperties" => true,
              "properties" => Ai::Tools::BaseTool::PENDING_RESULT_PROPERTIES
            }
          },
          "required" => [ "success" ]
        } ]),
        "The manifest outputSchema is no longer one shared literal across every " \
        "platform tool (#{schemas.size} distinct schemas). A per-tool — or better, " \
        "per-ACTION — outputSchema is the declaration the header's reason 1 says " \
        "does not exist; re-measure before extending this file."
      )
    end
  end

  it "keeps COVERED_CALLS disjoint from COVERED_DOCS" do
    overlap = covered_calls.keys & covered_docs
    expect(overlap).to(
      be_empty,
      "#{overlap.inspect} is in BOTH lists. COVERED_DOCS already checks every call in the " \
      "file, so the COVERED_CALLS entry is redundant — delete it."
    )
  end

  # Without this, adding a file to COVERED_DOCS and forgetting its pin gives
  # that file the parameter checks with no protection against its call sites
  # being deleted — the exact state IMP-4081ea184746 found every covered file
  # in. Both directions: a pin for a file that has LEFT COVERED_DOCS pins a
  # file nothing else checks, and reads as coverage.
  unpinned_covered, orphan_pins = pin_coverage_gaps(covered_docs, covered_doc_sites.keys)

  it "pins the call sites of every COVERED_DOCS file, and only those" do
    expect([ unpinned_covered, orphan_pins ]).to(
      eq([ [], [] ]),
      "COVERED_DOCS with no COVERED_DOC_CALL_SITES pin: #{unpinned_covered.inspect}. " \
      "COVERED_DOC_CALL_SITES naming a file not in COVERED_DOCS: #{orphan_pins.inspect}."
    )
  end

  # The two comparisons, on asymmetric fixture data. The examples generated
  # from the real lists cannot see either one's direction: the pin is exact on
  # this tree, so both set differences are empty in all 16 groups and an
  # inverted check — which would police what a doc has ADDED and ignore what it
  # has deleted, the opposite policy — reads as green everywhere.
  missing_when_a_site_is_gone   = missing_pinned_sites(pinned: %w[alpha beta beta], documented: %w[alpha beta])
  missing_when_a_site_is_added  = missing_pinned_sites(pinned: %w[alpha], documented: %w[alpha beta])
  missing_when_shape_changed    = missing_pinned_sites(pinned: %w[alpha], documented: %w[alpha()])
  gaps_when_a_pin_is_missing    = pin_coverage_gaps(%w[a.md b.md], %w[a.md])
  gaps_when_a_pin_is_orphaned   = pin_coverage_gaps(%w[a.md], %w[a.md b.md])

  it "reports a verb that has lost ONE of its several call sites" do
    expect(missing_when_a_site_is_gone).to eq([ "beta (have 1 of 2)" ])
  end

  it "reports nothing when the file documents a site it is not pinned for" do
    expect(missing_when_a_site_is_added).to be_empty
  end

  it "reports a braced site rewritten as a no-arg call" do
    expect(missing_when_shape_changed).to eq([ "alpha (have 0 of 1)" ])
  end

  it "reports a COVERED_DOCS file with no pin, on the first limb" do
    expect(gaps_when_a_pin_is_missing).to eq([ %w[b.md], [] ])
  end

  it "reports a pin naming a file that is not covered, on the second limb" do
    expect(gaps_when_a_pin_is_orphaned).to eq([ [], %w[b.md] ])
  end

  # Same vacuity trap as the COVERED_CALLS guard below: an empty list is a pin
  # that pins nothing and passes in silence.
  empty_pins = pins_without_sites(covered_doc_sites)
  empty_pins_in_fixture = pins_without_sites({ "a.md" => %w[x], "b.md" => [] })

  it "reports a pin that names a file but no call sites" do
    expect(empty_pins_in_fixture).to eq(%w[b.md])
  end

  it "names at least one call site per COVERED_DOC_CALL_SITES entry" do
    empty = empty_pins
    expect(empty).to(
      be_empty,
      "#{empty.inspect} pins no call sites. Remove the file from COVERED_DOCS, or name " \
      "what it documents."
    )
  end

  # An empty verb list is truthy, so it would filter every call away AND generate
  # no per-verb guard — the describe block would emit zero examples and report
  # green, which is the exact vacuity this mechanism exists to prevent.
  it "pins at least one verb per COVERED_CALLS entry" do
    empty = covered_calls.select { |_, verbs| verbs.empty? }.keys
    expect(empty).to(
      be_empty,
      "#{empty.inspect} lists no verbs. An empty list checks nothing and passes silently — " \
      "name the verbs, or delete the entry."
    )
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Parser coverage (IMP-f97c629e59d7).
  #
  # Every family in this file consumes extract_calls, so a call the parser
  # DROPS is invisible to all of them AND costs no example — the failure mode
  # is a silent green, which no doc-level assertion can see. These examples pin
  # the drop rules directly, on fixture text rather than on whichever doc
  # happens to carry the shape today, so the guarantee survives a doc edit.
  describe "extract_calls" do
    # The shape that was silently dropped: the whole example is commented out,
    # and the closing brace lands on a LATER `//` line. Skipping to end-of-line
    # at each `//` swallowed that brace, so the literal never balanced.
    framed_multiline = <<~MD
      ```javascript
      // platform.system_update_sensor_config({                                // aspirational
      //   sensor: "instance_status",
      //   silent_threshold_minutes: 10  // default 5
      // })
      ```
    MD

    # Control: a commented-out call that closes on its own line always parsed.
    framed_single_line = <<~MD
      ```javascript
      // platform.system_get_sensor_config({ sensor: "instance_status" })      // aspirational
      ```
    MD

    # Control: a genuinely truncated LIVE example must still be dropped —
    # extracting it would invent keys the doc does not show.
    #
    # truncated_live, truncated_live_then_comment and framed_then_unframed
    # carry no ``` fences on purpose. A backtick opens a string for the
    # scanner, so a fence silently swallows everything after it and would make
    # a be_empty expectation pass for the wrong reason — which is exactly how
    # the first draft of these let two over-reach mutants live. (The two
    # positive fixtures above keep their fences: there the raw scan starts past
    # the opening fence and the closing fence is unframed, so it ends the
    # region before any backtick is read.)
    truncated_live = <<~MD
      platform.system_get_node({ node_id: "<id>",
    MD

    # Control: a LIVE call is never comment-framed, so the retry must not run
    # for it. Without that anchoring, the `}` on the note below would close the
    # literal and the parser would report a call the doc does not make, with a
    # key ("the") invented out of English prose.
    truncated_live_then_comment = <<~MD
      platform.system_get_node({ node_id: "<id>",
      // the rest of this example was trimmed }
    MD

    # Control on the other side: the comment-framed region ends where the
    # comment block ends. Prose breaks the run, so the brace in the LATER,
    # unrelated comment block must not close this literal — the call stays
    # dropped rather than being reported with keys read out of English.
    framed_then_unframed = <<~MD
      // platform.system_get_node({
      //   node_id: "<id>",

      Prose between the two.

      // an unrelated later comment: }
    MD

    # Control: framing is recognised only at the START of the line. A `//`
    # earlier in a LIVE line (inside a URL, here) is not framing, and treating
    # it as such would close this truncated call on the note below it and
    # report `trimmed` — an English word — as a documented parameter.
    live_call_after_a_url = <<~MD
      See http://ops/x — platform.system_get_node({ node_id: "<id>",
      // trimmed }
    MD

    # Control: the region is seeded with the tail of the call's OWN line, so
    # keys that sit beside the opening brace are read like any other. Nothing
    # in the docs tree has this shape today, which is why it needs a fixture.
    framed_key_on_opening_line = <<~MD
      // platform.system_update_sensor_config({ sensor: "instance_status",
      //   silent_threshold_minutes: 10
      // })
    MD

    # A live call, for the commented/live distinction below.
    live_call = <<~MD
      platform.system_get_node({ node_id: "<id>" })
    MD

    # extract_calls is a class method on the group, so every fixture is parsed
    # HERE, at group-body scope, and the examples only assert on the results.
    framed_multiline_calls   = extract_calls(framed_multiline)
    framed_single_line_calls = extract_calls(framed_single_line)
    truncated_live_calls     = extract_calls(truncated_live)
    truncated_live_then_comment_calls = extract_calls(truncated_live_then_comment)
    framed_then_unframed_calls = extract_calls(framed_then_unframed)
    live_call_after_a_url_calls = extract_calls(live_call_after_a_url)
    framed_key_on_opening_line_calls = extract_calls(framed_key_on_opening_line)
    live_call_calls = extract_calls(live_call)

    it "extracts a commented-out call whose closing brace is on a later // line" do
      expect(framed_multiline_calls.map(&:first)).to(
        eq(%w[system_update_sensor_config]),
        "the call was DROPPED. Nothing else in this file can see that: a dropped call " \
        "generates no example, so the drop reads as a pass everywhere downstream."
      )
    end

    it "reads a comment-framed call's keys through the // framing" do
      expect(framed_multiline_calls.first&.at(1)&.map(&:first)).to eq(%w[sensor silent_threshold_minutes])
    end

    it "still extracts a commented-out call that closes on its own line" do
      expect(framed_single_line_calls.map { |verb, entries, _, _| [ verb, entries.map(&:first) ] }).to(
        eq([ [ "system_get_sensor_config", %w[sensor] ] ])
      )
    end

    it "drops a truncated LIVE call rather than inventing its arguments" do
      expect(truncated_live_calls).to be_empty
    end

    it "does not close a truncated LIVE call on a brace in the comment below it" do
      expect(truncated_live_then_comment_calls).to be_empty
    end

    it "does not stitch a comment-framed call across an unframed line" do
      expect(framed_then_unframed_calls).to be_empty
    end

    it "treats a mid-line // as a comment, not as framing" do
      expect(live_call_after_a_url_calls).to be_empty
    end

    it "reads a key written beside the opening brace of a framed call" do
      expect(framed_key_on_opening_line_calls.first&.at(1)&.map(&:first)).to(
        eq(%w[sensor silent_threshold_minutes])
      )
    end

    # IMP-6f2ebf01424a. The checker cannot honour the ASPIRATIONAL_VERBS
    # contract without this: an exemption's whole justification is that the doc
    # is COMMENTED OUT and marked aspirational, and the parser is the only
    # thing that knows whether that is true of a given site.
    it "reports whether a call site is commented out" do
      expect(framed_multiline_calls.first&.at(4)).to be(true)
    end

    it "reports a live call site as not commented out" do
      expect(live_call_calls.first&.at(4)).to be(false)
    end

    # The sweep consumes no-arg sites too, and exempts on the same rule, so the
    # flag has to be right for both shapes — not just the one that happens to
    # carry an exemption today.
    noarg_framed_calls = extract_noarg_calls("// platform.health()\n")
    noarg_live_calls   = extract_noarg_calls("platform.health()\n")

    it "reports a commented-out NO-ARG call site as commented out" do
      expect(noarg_framed_calls).to eq([ [ "health", 1, true ] ])
    end

    it "reports a live NO-ARG call site as not commented out" do
      expect(noarg_live_calls).to eq([ [ "health", 1, false ] ])
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Value shapes (IMP-389daefb3ab4).
  #
  # No doc in the covered set has a shape mismatch today, so the 134 examples
  # generated from real call sites are all green and can prove nothing about
  # the rule. These pin it on fixture data instead.
  describe "value shapes" do
    shaped = top_level_entries('a: { x: 1 }, b: [ 1 ], c: "s", d: ..., e, f: // note' + "\n" + ' { y: 2 }')

    it "reads each key's value shape" do
      expect(shaped).to eq(
        [ [ "a", :object ], [ "b", :array ], [ "c", :scalar ],
          [ "d", :elided ], [ "e", :shorthand ], [ "f", :object ] ]
      )
    end

    object_for_scalar  = shape_mismatches([ [ "k", :object ] ], { "k" => "string" })
    array_for_scalar   = shape_mismatches([ [ "k", :array ] ], { "k" => "string" })
    array_for_object   = shape_mismatches([ [ "k", :array ] ], { "k" => "object" })
    scalar_for_object  = shape_mismatches([ [ "k", :scalar ] ], { "k" => "object" })
    scalar_for_array   = shape_mismatches([ [ "k", :scalar ] ], { "k" => "array" })
    matching_object    = shape_mismatches([ [ "k", :object ] ], { "k" => "object" })
    undeclared_key     = shape_mismatches([ [ "k", :object ] ], {})
    elided_value       = shape_mismatches([ [ "k", :elided ] ], { "k" => "object" })
    shorthand_value    = shape_mismatches([ [ "k", :shorthand ] ], { "k" => "object" })
    scalar_type_pair   = shape_mismatches([ [ "k", :scalar ] ], { "k" => "integer" })

    it "reports an object where a scalar is declared" do
      expect(object_for_scalar).to eq([ "k: declared string, got object" ])
    end

    # NOT a mismatch, and the reason is in shape_mismatches: five live
    # parameters declare `string` and accept an encoded array, so the
    # declaration cannot tell a wrong array from a right one.
    it "accepts an array where a scalar is declared" do
      expect(array_for_scalar).to be_empty
    end

    it "reports a scalar where an object is declared" do
      expect(scalar_for_object).to eq([ "k: declared object, got scalar" ])
    end

    it "reports an array where an object is declared" do
      expect(array_for_object).to eq([ "k: declared object, got array" ])
    end

    it "reports a scalar where an array is declared" do
      expect(scalar_for_array).to eq([ "k: declared array, got scalar" ])
    end

    it "accepts a value whose shape matches" do
      expect(matching_object).to be_empty
    end

    # An unknown key is the unknown-key example's business, not this one's;
    # reporting it here would double every such failure.
    it "says nothing about a key the tool does not declare" do
      expect(undeclared_key).to be_empty
    end

    it "says nothing about an elided or shorthand value" do
      expect([ elided_value, shorthand_value ]).to eq([ [], [] ])
    end

    # Deliberate: docs write placeholders where real values go, so comparing
    # scalar TYPES would flag prose rather than defects.
    it "does not compare scalar types to each other" do
      expect(scalar_type_pair).to be_empty
    end
  end

  # IMP-6f2ebf01424a — an aspirational exemption covers a COMMENTED-OUT site
  # only.
  #
  # ASPIRATIONAL_VERBS is keyed [path, verb], and every rationale in it is an
  # argument about a commented-out example: the call is written out, marked
  # "aspirational" inline, and the prose beneath it names the real path. None
  # of that is an argument for exempting a LIVE call. A live call to a verb no
  # registry implements is the exact failure the tree-wide sweep exists to
  # catch — an operator copies it and it cannot run at all — and it is strictly
  # worse than the unlabelled case, because the doc is now prescribing the
  # fiction rather than describing it.
  #
  # Measured before this guard: planting
  # `platform.system_get_sensor_config({ sensor: "instance_status" })` live in
  # FLEET_SENSORS.md's own threshold section left the suite at 0 failures. The
  # exemption absorbed it in silence.
  #
  # This does NOT reverse the policy stated at ASPIRATIONAL_VERBS: being
  # commented out still exempts nothing on its own, and a commented-out call is
  # still parsed and checked like any other. It makes the comment marker
  # NECESSARY for an exemption, not sufficient — the hand-written entry is
  # still what grants it.
  def self.aspirational_exemption?(aspirational_verbs, relative_path, verb, commented)
    commented && aspirational_verbs.key?([ relative_path, verb ])
  end

  targets.each do |relative_path, only_verbs|
    describe(only_verbs ? "#{relative_path} (#{only_verbs.join(', ')} only)" : relative_path) do
      path = File.join(ext_root, relative_path)
      text = File.read(path)
      all_calls = extract_calls(text)
      calls = only_verbs ? all_calls.select { |verb, _, _, _| only_verbs.include?(verb) } : all_calls

      if only_verbs
        # Per-verb analogue of the whole-file guard below: without it, deleting
        # the pinned example makes this describe block generate no examples at
        # all and pass vacuously, which is exactly how the defect gets back in.
        only_verbs.each do |pinned|
          it "documents at least one platform.#{pinned} call" do
            expect(calls.map(&:first)).to(
              include(pinned),
              "#{relative_path} no longer calls #{pinned}. If the example was removed on " \
              "purpose, drop it from COVERED_CALLS too."
            )
          end
        end
      else
        it "documents at least one MCP call (the parser still matches this file)" do
          expect(calls).not_to be_empty
        end

        # The anti-deletion pin. The guard above only fires when EVERY call in
        # the file is gone; this one fires when any pinned call SITE goes,
        # which is what actually happens when an edit removes the example a
        # finding was closed by correcting. One token per site, `verb()` for a
        # no-arg call — see COVERED_DOC_CALL_SITES.
        documented_sites = all_calls.map(&:first) +
                           extract_noarg_calls(text).map { |verb, _line, _commented| "#{verb}()" }
        pinned_sites = covered_doc_sites.fetch(relative_path, [])
        missing_sites = missing_pinned_sites(pinned: pinned_sites, documented: documented_sites)

        it "still documents every call site it is pinned for" do
          # Anti-vacuity: a pin that resolves to nothing in this loop compares
          # an empty multiset against everything and passes in silence, which
          # is the same shape as the defect being fixed. The constant-level
          # guards cannot see this one — they check the hash, not the lookup.
          expect(pinned_sites).not_to(
            be_empty,
            "#{relative_path} resolved to an EMPTY pin here — COVERED_DOC_CALL_SITES has " \
            "no entry for it, or its entry is empty. The two constant-level guards above " \
            "say which."
          )

          expect(missing_sites).to(
            be_empty,
            "#{relative_path} no longer documents #{missing_sites.inspect}. Deleting a " \
            "call site silently removes the examples it generated — the file stays green " \
            "while the correction it was opted in for is gone. If the deletion was " \
            "deliberate, drop those tokens from COVERED_DOC_CALL_SITES in the same commit " \
            "and say why; if the VERB was renamed platform-side, rename the token; and if " \
            "the site was a KNOWN_BROKEN fiction, deleting it is the endorsed fix and the " \
            "token should go with it. Still documented: #{documented_sites.sort.inspect}"
          )
        end
      end

      calls.each do |verb, entries, line, elided|
        keys = entries.map(&:first)
        declared = declared_parameters(verb)

        # Verb EXISTENCE is not asserted here. It runs tree-wide and ungated in
        # the sweep at the bottom of this file, which already covers every file
        # in COVERED_DOCS/COVERED_CALLS; repeating it here would only duplicate
        # examples. The parameter checks below still need `declared`, so an
        # unregistered verb drops out of THIS block with no example — the sweep
        # is what reddens for it.
        next if declared.nil?

        tracked = known_broken[[relative_path, verb]]

        if tracked
          exercised_exclusions << [relative_path, verb]

          it "#{verb} at line #{line} is still the known-broken call its finding describes" do
            expect(keys & tracked).to(
              eq(tracked),
              "#{relative_path}:#{line} no longer calls #{verb} with #{tracked.inspect}. " \
              "If the tracked finding was fixed, delete this KNOWN_BROKEN entry so the " \
              "normal parameter checks apply to this call site."
            )
            expect(tracked - declared.keys).to(
              eq(tracked),
              "#{verb} now declares #{(tracked & declared.keys).inspect}. The finding this " \
              "exclusion tracks is resolved on the TOOL side — delete the KNOWN_BROKEN entry."
            )
          end
          next
        end

        it "#{verb} at line #{line} passes only parameters the tool declares" do
          unknown = keys - declared.keys
          expect(unknown).to(
            be_empty,
            "#{relative_path}:#{line} calls #{verb} with #{unknown.inspect}, " \
            "which #{verb} does not accept. Declared: #{declared.keys.sort.inspect}"
          )
        end

        # IMP-389daefb3ab4. The unknown-key example above proves the key is
        # accepted and stops there; nothing looked at what the doc puts under
        # it. So an example could nest a REQUIRED id inside an object — the
        # shape of the mistake this finding is about — and satisfy both of the
        # other checks. Runs for elided examples too: eliding OTHER arguments
        # says nothing about the shape of the ones actually shown.
        # No `|| {}`: declared_types and declared_parameters return nil under
        # byte-identical conditions and `declared.nil?` already returned above,
        # so a default here would only hide the silent-nil path the assertion
        # below exists to catch.
        types = declared_types(verb)
        mismatched = shape_mismatches(entries, types)

        it "#{verb} at line #{line} passes values of the shape the tool declares" do
          # Anti-vacuity. This check is silent across the whole tree today, so
          # a lookup that resolves to nothing is indistinguishable from a clean
          # pass — verified as a mutant, which survived until this assertion
          # existed. It is also a real consistency claim: declared_parameters
          # and declared_types read the two registries independently, and a
          # verb whose parameter set differs between them means one of the two
          # resolvers is wrong.
          expect(types.keys).to(
            match_array(declared.keys),
            "#{verb}: declared_types sees #{types.keys.sort.inspect} but declared_parameters " \
            "sees #{declared.keys.sort.inspect}. The two resolvers disagree, so the shape " \
            "check below is reading a different parameter set from the checks above."
          )

          expect(mismatched).to(
            be_empty,
            "#{relative_path}:#{line} calls #{verb} with #{mismatched.inspect}. An object " \
            "where a scalar is declared usually means the example nested the value under " \
            "an extra key; a scalar where an object is declared means the opposite. Note " \
            "that only the SHAPE is checked — no tool in the platform declares a nested " \
            "schema, so the keys INSIDE an object literal are still unguarded."
          )
        end

        # An explicitly elided example (`{ node_id: "...", ... }`) claims nothing
        # about completeness, so no required-parameter example is generated for
        # it. Its unknown-key example above still runs.
        next if elided

        it "#{verb} at line #{line} supplies every required parameter" do
          missing = declared.select { |_, required| required }.keys - keys
          expect(missing).to(
            be_empty,
            "#{relative_path}:#{line} calls #{verb} without required #{missing.inspect}. " \
            "Passed: #{keys.inspect}"
          )
        end
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Verb EXISTENCE, tree-wide and UNGATED (IMP-2a5a9a0fed0a).
  #
  # The asymmetry with the parameter checks above is DELIBERATE, not an
  # oversight in one direction or the other:
  #
  #   * The unknown-key and required-parameter checks stay opt-in per file
  #     (COVERED_DOCS) or per verb (COVERED_CALLS), because they are noisy.
  #     Measured 2026-08-31 by pointing covered_docs at every doc with a
  #     parseable call: 1017 examples, 77 failures still open against
  #     IMP-84c318bf31f9's drain. A file enters the allowlist only once it is
  #     genuinely clean, and opting in is that drain's acceptance signal.
  #     Do NOT ungate them in passing.
  #
  #   * Verb existence is a lookup, not a judgement: a verb resolves in
  #     PlatformApiToolRegistry::TOOLS / McpToolRegistrar::INTROSPECTION_TOOLS
  #     or it does not, so there is no backlog to drain before turning it on.
  #     It is also the worst of the three failure modes: a wrong KEY is either
  #     rejected or silently dropped, but a fictional VERB cannot be called at
  #     all, so the doc is not merely imprecise — it is unusable at the moment
  #     an operator is trusting it most. IMP-d40df31d9cef was exactly that
  #     (platform.list_vault_credentials, the only diagnostic 10-gitops-fleet.md
  #     offered for a failing sync), and this check would have caught it years
  #     earlier had it not been gated behind a per-file allowlist it was never
  #     added to.
  #
  #     Not literally false-positive-free, though, and do not sell it as such:
  #     from_tool_registry reads TOOLS[verb] and then requires an
  #     action_definitions entry, so a verb registered only through the generic
  #     register_extension_tools seam, or reachable only as an ACTION_ALIASES
  #     key, would report as unregistered. Neither is live — 0 of the doc
  #     verbs are alias keys and all resolve statically as of 2026-08-31 — but
  #     an exemption granted for that reason would be a lie, so widen the
  #     resolver instead if one ever appears.
  #
  # So this sweep reads the docs tree directly rather than either list, and a
  # doc added tomorrow is covered the day it lands with no opt-in step. It sees
  # both `platform.verb({ ... })` and no-arg `platform.verb()` sites, whether
  # live or commented out and however many lines they span, and descends
  # dot-directories. What it still cannot see is a call whose argument literal
  # never balances even after the comment framing is removed: a genuinely
  # truncated example, or one framed some way other than a line-leading `//`
  # (blockquoted, list-indented, or a run broken by a blank line). Neither has
  # a live instance as of 2026-08-31 — measured over all 31 docs, the new
  # parser drops 0 of the 325 call sites the bare regex finds, against 1 for
  # the old one — and extract_calls' own examples above pin the rules rather
  # than leaving them to this paragraph. "Tree-wide" is a claim about the
  # FILES swept; within a file it is bounded by what extract_calls can parse.
  aspirational_verbs = ModuleDocsMcpCallSignatures::ASPIRATIONAL_VERBS
  exercised_aspirational = []

  # The gate itself, on a real entry. The tree-wide guard below asserts that no
  # live call currently rides an exemption; it cannot see whether the gate
  # would DECLINE one, because with the docs clean both readings of the rule
  # agree on every site in the tree. These three pin the rule directly.
  # A synthetic one-entry list, NOT ASPIRATIONAL_VERBS itself. Every real entry
  # is designed to retire itself, so a hash that empties is the expected end
  # state — reading `keys.first` out of it would make these three examples fail
  # on the day the fiction is finally implemented, accusing a gate that is fine.
  sample_list = { [ "docs/zz_fixture.md", "zz_fixture_verb" ] => "fixture" }.freeze
  exemption_when_commented = aspirational_exemption?(sample_list, "docs/zz_fixture.md", "zz_fixture_verb", true)
  exemption_when_live      = aspirational_exemption?(sample_list, "docs/zz_fixture.md", "zz_fixture_verb", false)
  exemption_when_unlisted  = aspirational_exemption?(sample_list, "docs/zz_fixture.md", "zz_other_verb", true)

  it "grants an aspirational exemption to a commented-out, listed call site" do
    expect(exemption_when_commented).to be_truthy
  end

  it "declines the exemption when the same listed call is LIVE" do
    expect(exemption_when_live).to be_falsey
  end

  it "declines the exemption for a verb the list does not name" do
    expect(exemption_when_unlisted).to be_falsey
  end

  # File::FNM_DOTMATCH so DOT-directories are swept too. Without it Dir.glob
  # skips docs/.verify/ silently, which is where the sibling shell checker
  # (check-mcp-actions.sh) and its ASPIRATIONAL_MCP.md catalog live — the one
  # directory whose own docs are most likely to contain example call syntax.
  swept = Dir.glob(File.join(ext_root, "docs", "**", "*.md"), File::FNM_DOTMATCH)
             .sort.filter_map do |absolute|
    relative = absolute.delete_prefix("#{ext_root}/")
    text = File.read(absolute)
    # [verb, line] for both call shapes. The parameter families still see only
    # extract_calls; this pair is what the EXISTENCE check consumes.
    sites = extract_calls(text).map { |verb, _entries, line, _elided, commented|
              [ verb, line, commented ]
            } + extract_noarg_calls(text)
    [ relative, sites.sort_by { |_verb, line, _commented| line } ] unless sites.empty?
  end

  # Anti-vacuity, as an equality oracle rather than a "> 0" smoke test: a glob
  # that silently stops matching (a docs/ move, a renamed extension root) would
  # leave this sweep enumerating nothing and reporting green, which is the
  # failure mode the whole change exists to remove. Every file the opt-in lists
  # already name must appear here — if one does not, the sweep is not seeing
  # the tree it claims to.
  it "sweeps every doc the opt-in lists already name" do
    unswept = (covered_docs + covered_calls.keys) - swept.map(&:first)
    expect(unswept).to(
      be_empty,
      "#{unswept.inspect} is opted into the parameter checks but was not found by the " \
      "tree-wide sweep. The glob is not seeing the docs tree — fix it before trusting a " \
      "green run here."
    )
  end

  describe "verb existence (tree-wide, ungated by COVERED_DOCS)" do
    swept.each do |relative_path, sites|
      sites.each do |verb, line, commented|
        # Resolved here, at example-GROUP scope: declared_parameters is a class
        # method on this group and is not callable from inside an `it` block.
        declared = declared_parameters(verb)

        # Recorded on the LIST MATCH, not on the exemption. The guard below
        # asks whether an entry still matches a call site at all; an entry
        # whose example was merely UNCOMMENTED still matches one, and telling
        # its author "the example was probably removed — delete the entry"
        # would destroy the policy record over an edit that only needs the
        # comment markers put back.
        exercised_aspirational << [ relative_path, verb ] if aspirational_verbs.key?([ relative_path, verb ])

        if aspirational_exemption?(aspirational_verbs, relative_path, verb, commented)

          # Asserted STILL ABSENT, so the exemption retires itself.
          it "#{relative_path}:#{line} #{verb} is still unimplemented, as its exemption claims" do
            expect(declared).to(
              be_nil,
              "platform.#{verb} now resolves in a registry. ASPIRATIONAL_VERBS exempts it " \
              "on the claim that the platform does not implement it — that claim is now " \
              "false. Delete the entry so this call site is checked normally, and check " \
              "whether the surrounding prose still calls it aspirational."
            )
          end
          next
        end

        it "#{relative_path}:#{line} calls a registered MCP verb (#{verb})" do
          expect(declared).not_to(
            be_nil,
            "platform.#{verb} resolves in NEITHER Ai::Tools::PlatformApiToolRegistry::TOOLS " \
            "nor Ai::Introspection::McpToolRegistrar::INTROSPECTION_TOOLS, so an operator " \
            "copying #{relative_path}:#{line} cannot call it at all. Either the verb is " \
            "misspelled, or the doc describes a capability the platform does not have — in " \
            "which case COMMENT THE EXAMPLE OUT, say so in the prose, and add it to " \
            "ASPIRATIONAL_VERBS with a reason. An entry alone does NOT exempt a LIVE call " \
            "— the exemption is for a doc that describes a missing capability, not one " \
            "that prescribes it. Otherwise, implement the verb."
          )
        end
      end
    end
  end

  # The other half of the same contract, and DELIBERATELY redundant with the
  # gate rather than derived from it. This recomputes the decision from the
  # swept sites instead of reading what the gate decided.
  #
  # That redundancy is load-bearing, and mutation testing is how it was priced.
  # Hardcoding the gate's `commented` argument to true survives every example
  # here, because on a clean tree no listed verb has a live call site, so the
  # real flag and `true` agree everywhere — an equivalent mutant relative to
  # the docs corpus, and unkillable without planting the very defect the policy
  # forbids. Measured with the defect planted (a live
  # system_get_sensor_config call in FLEET_SENSORS.md): pristine gives 2
  # failures, that mutant gives 1 — this example. Deriving this guard from the
  # gate instead would have made the same mutant give 0, turning an equivalent
  # mutant into a lethal blind spot. Two independent detectors, on purpose.
  #
  # Independent in the gate WIRING and the list lookup, not in the flag: both
  # read comment_framed?, so a wrong flag defeats both at once. That predicate
  # is deliberately loose — it asks only whether the line opens with `//`, so a
  # line opening with a protocol-relative path would read as commented. No such
  # site exists: swept 2026-08-31, 351 call sites tree-wide, exactly 3 reported
  # commented and all 3 were genuine (FLEET_SENSORS.md:541 and :542,
  # node-provisioning.md:211). Re-swept for IMP-ca485128072e, which made the
  # FLEET_SENSORS.md pair LIVE: the corpus now reports ZERO commented call
  # sites, so `comment_framed?` is no longer exercised by real docs at all and
  # the synthetic `zz_fixture` corpus below is its ONLY remaining pin. Do not
  # delete that fixture on the grounds that nothing in the tree needs it —
  # nothing in the tree needing it is precisely the state it covers.
  #
  # It also names the situation outright, because the failure the gate produces
  # ("calls a registered MCP verb") does not say that an exemption was
  # declined, and the doc edit that causes it — uncommenting an aspirational
  # example, or writing a live one beside it — is the one an author is most
  # likely to make in good faith.
  it "exempts commented-out call sites only (no live call rides an exemption)" do
    live_exempted = swept.flat_map do |relative_path, sites|
      sites.filter_map do |verb, line, commented|
        "#{relative_path}:#{line} #{verb}" if !commented && aspirational_verbs.key?([ relative_path, verb ])
      end
    end
    expect(live_exempted).to(
      be_empty,
      "#{live_exempted.inspect} calls a verb ASPIRATIONAL_VERBS exempts, but the call is " \
      "LIVE, not commented out. The exemption's whole claim is that the doc describes " \
      "something that does not exist yet; a live call PRESCRIBES it, and an operator " \
      "copying it cannot run it at all. Comment the example out, or implement the verb."
    )
  end

  # Same staleness guard the KNOWN_BROKEN list gets below, and for the same
  # reason: deleting the exempted example leaves the entry matching no call
  # site, so its self-retiring assertion never runs and the exemption survives
  # forever with nothing to flag it.
  it "exercises every ASPIRATIONAL_VERBS exemption (none has gone stale)" do
    expect(exercised_aspirational.uniq).to(
      match_array(aspirational_verbs.keys),
      "ASPIRATIONAL_VERBS entries that matched no call site: " \
      "#{(aspirational_verbs.keys - exercised_aspirational.uniq).inspect}. The example was " \
      "probably removed or reworded — delete the entry."
    )
  end

  # The derivation oracle. See ASPIRATIONAL_CATALOG_PATH above for why this
  # direction and not the other, and for the three anti-vacuity pins these
  # four examples implement.
  describe "docs/.verify/ASPIRATIONAL_MCP.md (derived from ASPIRATIONAL_VERBS)" do
    catalog_path = File.join(ext_root, ModuleDocsMcpCallSignatures::ASPIRATIONAL_CATALOG_PATH)
    catalog_text = File.exist?(catalog_path) ? File.read(catalog_path) : nil
    catalog_rows = catalog_text && ModuleDocsMcpCallSignatures.parse_aspirational_catalog(catalog_text)

    it "exists on disk" do
      expect(catalog_text).not_to(
        be_nil,
        "#{ModuleDocsMcpCallSignatures::ASPIRATIONAL_CATALOG_PATH} is gone. It is the " \
        "operator-facing view of ASPIRATIONAL_VERBS and check-mcp-actions.sh reads it to " \
        "tell a catalogued aspirational reference from real drift. Restore it or retire " \
        "both consumers together."
      )
    end

    # Pin 1: the machine-readable region must be present. Without this, renaming
    # or dropping the markers turns the parse into `nil`, the row set into
    # nothing, and — on the day ASPIRATIONAL_VERBS empties — the equality
    # example below into a green that proves nothing.
    it "carries the machine-readable catalog markers" do
      expect(catalog_rows).not_to(
        be_nil,
        "#{ModuleDocsMcpCallSignatures::ASPIRATIONAL_CATALOG_BEGIN} / " \
        "#{ModuleDocsMcpCallSignatures::ASPIRATIONAL_CATALOG_END} not found in " \
        "#{ModuleDocsMcpCallSignatures::ASPIRATIONAL_CATALOG_PATH}. The table between them " \
        "is parsed by this spec and by check-mcp-actions.sh — the markers are not " \
        "decoration, and a catalog without them reads as empty to both."
      )
    end

    # Pin 2: a non-empty source must yield a non-empty parse. Equality alone
    # cannot catch a parser that matches nothing once the source also empties.
    it "parses at least one row while ASPIRATIONAL_VERBS is non-empty" do
      skip "ASPIRATIONAL_VERBS is empty — nothing to derive" if aspirational_verbs.empty?

      expect(catalog_rows).not_to(
        be_empty,
        "The catalog region exists but parsed to zero rows while ASPIRATIONAL_VERBS holds " \
        "#{aspirational_verbs.size}. Rows must be `| `verb` | `doc/path.md` | workaround |` " \
        "with the verb and doc BACKTICKED and the verb written bare (no platform. prefix)."
      )
    end

    # Pin 3: equality on [doc, verb] pairs, both directions.
    it "lists exactly the ASPIRATIONAL_VERBS entries, no more and no fewer" do
      expect(catalog_rows || []).to(
        match_array(aspirational_verbs.keys),
        "docs/.verify/ASPIRATIONAL_MCP.md has drifted from ASPIRATIONAL_VERBS.\n" \
        "  missing from the catalog: #{(aspirational_verbs.keys - (catalog_rows || [])).inspect}\n" \
        "  in the catalog but not the list: #{((catalog_rows || []) - aspirational_verbs.keys).inspect}\n" \
        "ASPIRATIONAL_VERBS is the source of truth; edit the markdown to match it. Do NOT " \
        "edit the list to match the markdown, and do NOT take the count from a " \
        "check-mcp-actions.sh run — that script cannot see a commented-out call site, which " \
        "is what every entry here is."
      )
    end
  end

  # Without this, a KNOWN_BROKEN entry can rot silently. Deleting the offending
  # example outright is a legitimate fix for both tracked findings, and it makes
  # extract_calls yield nothing for that verb — so no `it` block is generated,
  # the self-retiring assertion above never runs, and the stale exclusion (plus
  # the finding id it points at) survives forever with nothing to flag it. The
  # per-file "documents at least one MCP call" guard does not catch this: it
  # only fires when EVERY call in the file is gone.
  it "exercises every KNOWN_BROKEN exclusion (none has gone stale)" do
    expected = known_broken.keys.select do |path, verb|
      covered_docs.include?(path) || covered_calls[path]&.include?(verb)
    end
    expect(exercised_exclusions.uniq).to(
      match_array(expected),
      "KNOWN_BROKEN entries that matched no call site: "       "#{(expected - exercised_exclusions.uniq).inspect}. The example was probably "       "removed or reworded — delete the entry and its finding reference."
    )
  end
end
