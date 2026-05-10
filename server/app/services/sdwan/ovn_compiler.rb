# frozen_string_literal: true

# Sdwan::OvnCompiler — translates the platform's OVN model rows into a
# structured `ovn-nbctl` command plan.
#
# Output shape (compile_for_deployment):
#   {
#     deployment_id: "<uuid>",
#     plan: [
#       { cmd: "ls-add",            args: ["my-switch"] },
#       { cmd: "lsp-add",           args: ["my-switch", "vm-001"] },
#       { cmd: "lsp-set-addresses", args: ["vm-001", "02:11:22:33:44:55 10.0.0.5"] },
#       ...
#     ],
#     compiled_at: "2026-05-10T..."
#   }
#
# Emission order (dependency-respecting, stable):
#   1. ls-add for every active switch, ordered by switch name
#   2. for each switch (in the same order):
#        - lsp-add for every active port, ordered by port name
#        - lsp-set-addresses for each port that carries any addresses
#        - lsp-set-type for external ports
#
# Idempotency contract:
#   * Re-compiling the same DB state produces a byte-identical plan.
#     We achieve this by ordering by `name` (not `id`/`created_at`) at
#     every level, since names are unique per scope (deployment for
#     switches, switch for ports).
#   * Removed rows are excluded — the compiler only emits for `active`.
#   * The compiler does NOT execute. It returns the plan as data; an
#     executor (or operator running `ovn-nbctl`) replays the entries.
#
# The compiler is intentionally minimal in O3: no ACLs, no logical
# routers, no DHCP. Those land in later phases. The plan's structured
# shape (cmd + args) leaves room to grow without changing the
# consumer contract.
#
# Phase O3 of the OVS+OVN dual-profile roadmap (heavyweight track).
module Sdwan
  class OvnCompiler
    # Convenience entry point — operator-facing tools call this with a
    # deployment row and consume the structured plan directly.
    def self.compile_for_deployment(deployment)
      new(deployment).compile
    end

    def initialize(deployment)
      raise ArgumentError, "deployment is required" if deployment.nil?

      @deployment = deployment
      # Eager-load active switches and their active ports in one go so
      # the compiler doesn't issue N+1 queries when a deployment has
      # hundreds of switches. We sort in Ruby (not SQL) to keep the
      # ordering rule one-line obvious; row counts are tiny vs DB load.
      @switches = @deployment.logical_switches
                             .compilable
                             .includes(:ports, :acls)
                             .to_a
                             .sort_by(&:name)
    end

    def compile
      {
        deployment_id: @deployment.id,
        plan: build_plan,
        compiled_at: Time.current.utc.iso8601
      }
    end

    # ---------------------------------------------------------------
    # Internal helpers — public for spec coverage.
    # ---------------------------------------------------------------

    def build_plan
      entries = []

      # Phase 1 — every active switch lands first. Without the parent
      # switch, `lsp-add` would fail because `ovn-nbctl` rejects
      # ports against a non-existent switch.
      @switches.each do |switch|
        entries << { cmd: "ls-add", args: [switch.name] }
      end

      # Phase 2 — emit all ports for each switch in turn. We iterate
      # switches in the same order as phase 1 so the overall plan
      # reads top-to-bottom in a way that matches operator mental
      # model ("here are my switches; here are the ports on each").
      @switches.each do |switch|
        ports_for(switch).each do |port|
          entries.concat(port_entries(switch, port))
        end
      end

      # Phase 3 — emit ACLs after switches + ports. ACLs reference
      # the switch by name and OVN rejects them if the switch doesn't
      # exist yet, so order matters. ACLs at higher priority emit
      # first to match OVN's evaluation order; ties broken by name.
      @switches.each do |switch|
        acls_for(switch).each do |acl|
          entries << acl_entry(switch, acl)
        end
      end

      entries
    end

    private

    def ports_for(switch)
      # Active ports only, sorted by name for byte-stable output.
      # We rely on the `includes(:ports)` from the constructor so this
      # is a pure in-memory filter; no extra queries.
      switch.ports.select { |p| p.state == "active" }.sort_by(&:name)
    end

    def acls_for(switch)
      # Active ACLs only, sorted by (priority desc, name asc) so the
      # compiled plan emits in OVN's evaluation order. In-memory filter
      # via the constructor's includes(:acls) — no extra queries.
      switch.acls
            .select { |a| a.state == "active" }
            .sort_by { |a| [ -a.priority, a.name ] }
    end

    # Emits the per-ACL command:
    #   acl-add <switch> <direction> <priority> "<match>" <action>
    #
    # OVN expects the match expression as a single quoted string. The
    # `cmd + args` shape leaves quoting to the consumer (executor /
    # operator); the args list carries the unquoted parts.
    def acl_entry(switch, acl)
      {
        cmd:  "acl-add",
        args: [ switch.name, acl.direction, acl.priority.to_s, acl.match, acl.action ]
      }
    end

    # Emits the per-port command sequence:
    #   lsp-add <switch> <port>
    #   [lsp-set-type <port> <type>]                 (external only)
    #   [lsp-set-addresses <port> "<mac> <ip> ...">  (when present)
    def port_entries(switch, port)
      out = []
      out << { cmd: "lsp-add", args: [switch.name, port.name] }

      # External ports get a type marker so OVN treats them as
      # localnet/router uplinks rather than VM ports. The type value
      # ("localnet") is the standard OVN choice for external uplinks;
      # operators can override via port.settings["ovn_type"] when
      # they need a different OVN type (e.g. "router").
      if port.kind == "external"
        type_value = port.settings.fetch("ovn_type", "localnet")
        out << { cmd: "lsp-set-type", args: [port.name, type_value.to_s] }
      end

      # OVN's `addresses=` is a single string with the MAC first and
      # any IPv4/IPv6 values space-separated after it. We always
      # emit the MAC; IPs are appended only when the row carries any.
      addresses_string = build_addresses_string(port)
      out << { cmd: "lsp-set-addresses", args: [port.name, addresses_string] }

      out
    end

    # Joins the port's MAC and address list into OVN's expected
    # single-string form. Returns just the MAC when no IPs are set.
    def build_addresses_string(port)
      ips = Array(port.addresses).reject(&:blank?)
      ([port.mac] + ips).join(" ")
    end
  end
end
