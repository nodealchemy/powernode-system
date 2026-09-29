# frozen_string_literal: true

require "rails_helper"

# IMP-52762a704a3d — the SERVER half of the read-only node inspection task
# (probe.node_inspect). The agent re-validates every argument (package
# taskguard) and is the load-bearing half; this class refuses the same values
# before a task row exists, and is the one place the verb, the model and the
# tests read the collector list from.
RSpec.describe System::NodeInspection do
  def options_for(collector, **rest)
    described_class.options_from({ collector: collector }.merge(rest))
  end

  def refused(collector, **rest)
    expect { options_for(collector, **rest) }.to raise_error(described_class::Invalid)
  end

  describe "the fixed collector set" do
    it "is exactly the seven read collectors, each with its declared arguments" do
      expect(described_class::COLLECTORS).to eq(
        "wg_status" => %w[interface], "routes" => [], "nft" => %w[scope], "journal" => %w[unit lines],
        "unit" => %w[unit], "caps" => %w[unit], "file_stat" => %w[path]
      )
    end

    it "is frozen, so nothing can add an eighth at runtime" do
      expect(described_class::COLLECTORS).to be_frozen
      expect(described_class::COLLECTORS.values).to all(be_frozen)
    end
  end

  describe ".options_from" do
    it "builds the option hash the agent expects, with string keys and only declared arguments" do
      expect(options_for("wg_status", interface: "wg0")).to eq("collector" => "wg_status", "interface" => "wg0")
      expect(options_for("routes")).to eq("collector" => "routes")
      expect(options_for("nft")).to eq("collector" => "nft", "scope" => "ruleset")
      expect(options_for("nft", scope: "chains")).to eq("collector" => "nft", "scope" => "chains")
      expect(options_for("unit", unit: "sshd.service")).to eq("collector" => "unit", "unit" => "sshd.service")
      expect(options_for("caps", unit: "sshd.service")).to eq("collector" => "caps", "unit" => "sshd.service")
      expect(options_for("file_stat", path: "/etc/hostname")).to eq("collector" => "file_stat", "path" => "/etc/hostname")
    end

    it "defaults the journal to 100 lines and sends the count as an Integer" do
      expect(options_for("journal", unit: "sshd.service")).to eq("collector" => "journal", "unit" => "sshd.service", "lines" => 100)
      expect(options_for("journal", unit: "sshd.service", lines: "25")["lines"]).to eq(25)
      expect(options_for("journal", unit: "sshd.service", lines: 500)["lines"]).to eq(500)
    end

    it "refuses an unknown, blank or wrongly-typed collector" do
      [ "ssh", "sh", "", nil, "WG_STATUS", "wg_dump", "wg_status ", 7, [ "routes" ] ].each do |c|
        expect { described_class.options_from({ collector: c }) }.to raise_error(described_class::Invalid), c.inspect
      end
    end

    it "refuses an argument the collector does not declare, instead of ignoring it" do
      refused("routes", interface: "wg0")
      refused("wg_status", interface: "wg0", path: "/etc/hostname")
      refused("journal", unit: "a.service", path: "/etc/hostname")
      refused("caps", unit: "a.service", lines: 5)
      refused("file_stat", path: "/etc/hostname", unit: "a.service")
      refused("nft", scope: "ruleset", interface: "wg0")
    end

    it "ignores blank values for arguments a collector does not declare (a client sending empty strings)" do
      expect(options_for("routes", interface: "", unit: nil, path: "")).to eq("collector" => "routes")
    end

    describe "interface" do
      it "refuses the wg show keywords, option-shaped names and anything outside the charset" do
        [ "all", "interfaces", "ALL", "-x", "--help", ".wg0", "..", "wg0/x", "wg0 dump", "wg0\nall", "wg0;id",
          "a" * 16, "wgé0", "wg$0", "", nil, 5 ].each do |v|
          expect { options_for("wg_status", interface: v) }.to raise_error(described_class::Invalid), v.inspect
        end
      end

      it "accepts ordinary interface names" do
        [ "wg0", "wg-sdwan", "vrf_mgmt", "eth0.100", "a", "a" * 15 ].each do |v|
          expect(options_for("wg_status", interface: v)["interface"]).to eq(v)
        end
      end
    end

    describe "unit" do
      %w[journal unit caps].each do |collector|
        it "#{collector}: refuses a shorthand, option, glob or traversal and accepts full unit names" do
          [ "sshd", "--all.service", "ssh*.service", "../x.service", "a b.service", "a.service\nb.service",
            ".service", "-x.service", ".hidden.service", "a" * 260 + ".service", "", nil, 4 ].each do |v|
            expect { options_for(collector, unit: v) }.to raise_error(described_class::Invalid), v.inspect
          end
          %w[sshd.service powernode-agent.service getty@tty1.service persist-volumes-pg:main.mount multi-user.target
             fstrim.timer dbus.socket system.slice].each do |v|
            expect(options_for(collector, unit: v)["unit"]).to eq(v)
          end
        end
      end
    end

    describe "journal lines" do
      it "refuses zero, negative, over-cap, fractional and non-numeric counts" do
        [ 0, -1, 501, 1_000_000_000, 1.5, "abc", "5.5", "", true, [ 5 ], { "n" => 5 } ].each do |v|
          next if v == "" # blank means "use the default", like an absent key

          expect { options_for("journal", unit: "a.service", lines: v) }.to raise_error(described_class::Invalid), v.inspect
        end
      end
    end

    describe "nft scope" do
      it "refuses everything but ruleset and chains" do
        [ "flush ruleset", "table inet filter", "RULESET", " ruleset", 3, [ "ruleset" ] ].each do |v|
          expect { options_for("nft", scope: v) }.to raise_error(described_class::Invalid), v.inspect
        end
      end
    end

    describe "file_stat path" do
      it "accepts paths under the allow-list" do
        %w[/etc/hostname /etc/systemd/system/powernode-x-rails.service /etc/passwd /usr/sbin/powernode-agent
           /boot/loader/loader.conf /persist/var/lib/powernode/state.json /run/powernode/marker /etc].each do |v|
          expect(options_for("file_stat", path: v)["path"]).to eq(v), v
        end
      end

      it "refuses relative, traversing, non-canonical and control-character paths" do
        [ "", "etc/hostname", "/etc/../etc/shadow", "/etc/./hostname", "/etc//hostname", "/etc/hostname\n/etc/shadow",
          "/etc/host name", "/etc/host\u0000name", "/" ].each do |v|
          expect { options_for("file_stat", path: v) }.to raise_error(described_class::Invalid), v.inspect
        end
      end

      it "refuses everything outside the allow-list, /proc/*/environ included" do
        %w[/proc/1/environ /proc/self/environ /proc/1/mem /sys/kernel/notes /dev/sda /root/.bash_history /tmp/x
           /home/u/.ssh/id_ed25519 /var/log/auth.log /sysroot/etc/shadow /persist/volumes/pg/PG_VERSION /persist/anything
           /etcetera/hostname /usrx/bin/ls /run/user/0/bus].each do |v|
          expect { options_for("file_stat", path: v) }.to raise_error(described_class::Invalid), v
        end
      end

      it "refuses secret locations even inside the allow-list" do
        %w[/etc/shadow /etc/shadow- /etc/gshadow /etc/security/opasswd /etc/security/limits.conf
           /etc/ssh/ssh_host_ed25519_key /etc/ssl/private/server.pem /etc/wireguard/wg0.conf
           /persist/var/lib/powernode/pki/node.key /persist/var/lib/powernode/pki /etc/powernode/pki/ca-chain.pem
           /run/powernode/storage/keys/cred /etc/powernode/credentials/db /etc/app/secrets/token /etc/app/private/x.conf
           /etc/skel/.ssh/id_rsa /etc/app/server.key /etc/app/server-key.pem /etc/letsencrypt/live/x/privkey.pem
           /etc/app/store.p12 /etc/app/id_rsa /etc/app/app.env /etc/app/.env /etc/app/.netrc /etc/nginx/.htpasswd
           /etc/powernode/enroll-token /etc/app/client_secret /etc/app/db-password /etc/app/credentials.json
           /etc/SHADOW /etc/app/SERVER.KEY /etc/app/signing_key].each do |v|
          expect { options_for("file_stat", path: v) }.to raise_error(described_class::Invalid), v
        end
        expect(options_for("file_stat", path: "/etc/ssh/ssh_host_ed25519_key.pub")["path"])
          .to eq("/etc/ssh/ssh_host_ed25519_key.pub")
      end
    end
  end

  describe ".validate!" do
    it "accepts the options options_from builds" do
      expect { described_class.validate!(options_for("journal", unit: "a.service", lines: 10)) }.not_to raise_error
    end

    it "is strict about keys: a hand-written option hash may not carry a command or an undeclared key" do
      [ { "collector" => "routes", "command" => "id" },
        { "collector" => "wg_status", "interface" => "wg0", "args" => [ "dump" ] },
        { "collector" => "file_stat", "path" => "/etc/hostname", "sudo" => true } ].each do |opts|
        expect { described_class.validate!(opts) }.to raise_error(described_class::Invalid), opts.inspect
      end
    end

    it "requires a string journal line count that is already an Integer (what the agent reads)" do
      expect { described_class.validate!("collector" => "journal", "unit" => "a.service", "lines" => "5") }
        .to raise_error(described_class::Invalid)
      expect { described_class.validate!("collector" => "journal", "unit" => "a.service") }.not_to raise_error
    end

    it "refuses a non-hash" do
      [ nil, "routes", [ "routes" ] ].each { |v| expect { described_class.validate!(v) }.to raise_error(described_class::Invalid) }
    end
  end

  # ONE table, two implementations. agent/internal/taskguard/testdata/
  # inspect_cases.json is read by the Go taskguard test as well, so a rule stated
  # differently on the two sides (a character set, a length counted in characters
  # rather than bytes) fails one of them. The Go-source parity below covers the
  # LISTS; this covers the CHARSET and LENGTH rules the lists do not.
  describe "shared charset and length cases with the agent" do
    let(:cases) do
      raw = JSON.parse(Rails.root.join("..", "extensions", "system", "agent", "internal", "taskguard", "testdata", "inspect_cases.json").read)
      raw.reject { |k, _| k.start_with?("_") }.transform_values do |list|
        list.map { |e| e.is_a?(Hash) ? "#{e['prefix']}#{e['repeat'] * e['times']}#{e['suffix']}" : e }
      end
    end

    def accepts?(collector, key, value)
      options_for(collector, key => value)
      true
    rescue described_class::Invalid
      false
    end

    it "carries every case group, non-empty" do
      expect(cases.keys).to match_array(%w[path_ok path_refused interface_ok interface_refused unit_ok unit_refused])
      expect(cases.values).to all(be_present)
    end

    it "agrees on file_stat paths" do
      wrong_ok = cases["path_ok"].reject { |v| accepts?("file_stat", :path, v) }
      wrong_refused = cases["path_refused"].select { |v| accepts?("file_stat", :path, v) }
      expect(wrong_ok).to eq([]), "server refuses what the agent accepts: #{wrong_ok.map { |v| v[0, 60] }.inspect}"
      expect(wrong_refused).to eq([]), "server accepts what the agent refuses: #{wrong_refused.map { |v| v[0, 60] }.inspect}"
    end

    it "agrees on interface names" do
      expect(cases["interface_ok"].reject { |v| accepts?("wg_status", :interface, v) }).to eq([])
      expect(cases["interface_refused"].select { |v| accepts?("wg_status", :interface, v) }).to eq([])
    end

    it "agrees on unit names" do
      expect(cases["unit_ok"].reject { |v| accepts?("unit", :unit, v) }).to eq([])
      expect(cases["unit_refused"].select { |v| accepts?("unit", :unit, v) }).to eq([])
    end
  end

  # The agent is authoritative and this class mirrors it. Reading the Go source
  # here means the two lists cannot drift apart silently: editing either side
  # alone reds this example. (The same parity technique
  # spec/lint/agent_handles_every_task_command_spec.rb uses for the command set.)
  describe "parity with the agent's Go source" do
    let(:agent_dir) { Rails.root.join("..", "extensions", "system", "agent", "internal") }
    let(:handler_src) { File.read(agent_dir.join("runtime", "tasks", "handlers", "probe_node_inspect.go")) }
    let(:guard_src) { File.read(agent_dir.join("taskguard", "inspect.go")) }

    def go_string_list(src, var)
      body = src[/^var #{var}\s*=\s*\[\]string\{(.*?)\}/m, 1] or raise "cannot find Go var #{var}"
      body.scan(/"([^"]*)"/).flatten
    end

    def go_string_map_keys(src, var)
      body = src[/^var #{var}\s*=\s*map\[string\][^{]*\{(.*?)^\}/m, 1] or raise "cannot find Go map #{var}"
      body.scan(/"([^"]+)"\s*:/).flatten
    end

    it "declares the same collectors with the same arguments" do
      body = handler_src[/^var nodeInspectCollectors\s*=\s*map\[string\]\[\]string\{(.*?)^\}/m, 1]
      go = body.scan(/"([a-z_]+)":\s*\{([^}]*)\}/).to_h { |name, args| [ name, args.scan(/"([a-z_]+)"/).flatten ] }
      expect(go).to eq(described_class::COLLECTORS)
    end

    it "carries the same file_stat allow-list and secret rules" do
      expect(go_string_list(guard_src, "inspectAllowedPrefixes")).to eq(described_class::ALLOWED_PATH_PREFIXES)
      expect(go_string_map_keys(guard_src, "inspectDeniedSegments")).to match_array(described_class::DENIED_PATH_SEGMENTS)
      expect(go_string_list(guard_src, "inspectDeniedSubstrings")).to eq(described_class::DENIED_NAME_SUBSTRINGS)
      expect(go_string_list(guard_src, "inspectDeniedSuffixes")).to eq(described_class::DENIED_NAME_SUFFIXES)
      expect(go_string_list(guard_src, "inspectDeniedPrefixes")).to eq(described_class::DENIED_NAME_PREFIXES)
    end

    it "carries the same unit suffixes and reserved interface words" do
      expect(go_string_list(guard_src, "systemdUnitSuffixes")).to eq(described_class::UNIT_SUFFIXES)
      reserved = guard_src[/^var reservedInterfaces\s*=\s*map\[string\]bool\{(.*?)\}/m, 1].scan(/"([^"]+)"/).flatten
      expect(reserved).to match_array(described_class::RESERVED_INTERFACES)
    end

    it "carries the same journal line bounds and nft scopes" do
      expect(handler_src[/inspectDefaultJournalLines\s*=\s*(\d+)/, 1].to_i).to eq(described_class::JOURNAL_DEFAULT_LINES)
      expect(handler_src[/inspectMaxJournalLines\s*=\s*(\d+)/, 1].to_i).to eq(described_class::JOURNAL_MAX_LINES)
      expect(go_string_map_keys(handler_src, "nftScopes")).to match_array(described_class::NFT_SCOPES)
    end

    it "is registered under the command the model mints" do
      expect(handler_src).to include('r.Register("probe.node_inspect"')
      expect(described_class::COMMAND).to eq("probe.node_inspect")
    end
  end
end
