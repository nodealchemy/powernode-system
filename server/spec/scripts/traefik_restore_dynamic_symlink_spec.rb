# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

# IMP-7e08f1514046 — traefik-restore-dynamic.sh runs as root at every boot
# and copies $SRC_DIR/00-host-login.yaml into $DST_DIR. $SRC_DIR
# (/persist/powernode-traefik/dynamic) is 2775 root:traefik with no sticky
# bit, and the rails service user is a member of the traefik group.
#
# ROUND 2 (review): round 1 closed the symlink path (`-L` before `-f`) but
# missed a HARDLINK — a hardlink to a root-readable-only file is a regular
# file in its own right and passes `-L`/`-f` cleanly, since the kernel
# enforces access on the OPEN, not on a path test. Round 2 reads $SRC with
# DROPPED privileges (setpriv, uid 65534) under a byte cap and a timeout, so
# the kernel's own permission check — not this script's path tests — decides
# whether a hardlinked/raced source can be read at all. Round 2 also: treats
# $DST_DIR being a symlink straight to $SRC_DIR (the module-composed case,
# agent compose.go:531) as expected (INFO, not a refusal); stopped chowning
# $DST_DIR itself (that broke rails's own 2775 write access — rails-setup.sh
# needs it); and moved refusal logging to WARNING (stderr, `<4>` prefix).
#
# Every example below genuinely EXECUTES the whole script via Open3.capture3,
# planting real attack fixtures on disk — not source-text regex matching.
# The script drops privilege via `setpriv` and resolves the traefik group via
# `getent`, neither of which this non-root test runner can do for real
# (setpriv --reuid needs CAP_SETUID; there is no `traefik` group on this
# box) — both are PATH-shimmed:
#   - `getent`: answers "group traefik" with a fixed fake gid; forwards any
#     other query to the real binary.
#   - `setpriv`: cannot actually drop to uid 65534 without real root, so it
#     APPROXIMATES what that drop would mean for THIS script's two calls
#     (`head -c N -- $SRC`, `test -f $f`) by checking whether the target's
#     "other" bits are readable — the same practical constraint an
#     unrelated, unprivileged uid reduces to for a file it doesn't own.
#     A hardlink to a 0600 file the test process itself created (owner
#     doesn't matter — the shim never looks at it) is therefore refused by
#     the shim exactly as a real uid-65534 open() would refuse it.
#   - `chown`: real chown to root:root would fail outright as non-root
#     regardless of WHICH path it targeted, which would make a
#     "DST_DIR is never chowned" assertion pass for the wrong reason; shimmed
#     so the assertion is about which paths the script attempts, not whether
#     the attempt would have succeeded.
#   - `chmod` is NOT shimmed: chmod-ing a file/dir this test process itself
#     owns needs no privilege, so the real command runs and its effect
#     (mode 0644 on the published file, 0700 on the staging dir) is asserted
#     directly.
RSpec.describe "traefik-restore-dynamic.sh: symlink- and hardlink-safe persisted ingress restore (IMP-7e08f1514046)" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:script_path) do
    File.join(extension_root, "modules/reverse-proxy-traefik/rootfs/usr/local/bin/traefik-restore-dynamic.sh")
  end
  let(:script) { File.read(script_path) }

  describe "script integrity" do
    it "is valid POSIX sh (sh -n)" do
      _out, err, status = Open3.capture3("sh", "-n", script_path)
      expect(status.success?).to be(true), "sh -n failed: #{err}"
    end

    it "declares #!/bin/sh as its shebang" do
      expect(script.lines.first).to eq("#!/bin/sh\n")
    end

    it "passes shellcheck, when the binary is available in this environment" do
      skip "shellcheck not installed in this environment" unless system("which shellcheck > /dev/null 2>&1")

      out, _err, status = Open3.capture3("shellcheck", "-S", "error", script_path)
      expect(status.success?).to be(true), "shellcheck -S error failed:\n#{out}"
    end
  end

  describe "genuine execution" do
    let(:persist_dir) { Dir.mktmpdir }
    let(:base_dir) { Dir.mktmpdir }
    let(:dst_dir) { File.join(base_dir, "dynamic") }
    let(:shim_dir) { Dir.mktmpdir }
    let(:chown_log) { File.join(shim_dir, "chown.log") }
    let(:name_file) { File.join(dst_dir, "00-host-login.yaml") }

    before do
      write_shim("chown", <<~SH)
        #!/bin/sh
        echo "chown $*" >> #{chown_log}
        exit 0
      SH

      write_shim("getent", <<~SH)
        #!/bin/sh
        if [ "$1" = "group" ] && [ "$2" = "traefik" ]; then
          echo "traefik:x:5555:"
          exit 0
        fi
        exec /usr/bin/getent "$@"
      SH

      # See file header: approximates a uid-65534 drop by checking the
      # LAST argument's "other"-readable bit, which is what this script's
      # two setpriv-wrapped calls (head, test -f) actually depend on.
      write_shim("setpriv", <<~'SH')
        #!/bin/sh
        # TEST_SETPRIV_SLEEP is a test-only hook (unset in production; the
        # real script never sets it) that lets one spec put the script
        # mid-flight, inside this call, long enough to deliver a signal.
        [ -n "${TEST_SETPRIV_SLEEP:-}" ] && sleep "$TEST_SETPRIV_SLEEP"
        while [ $# -gt 0 ]; do
          case "$1" in
            --) shift; break ;;
            --reuid=*|--regid=*|--clear-groups|--no-new-privs) shift ;;
            *) break ;;
          esac
        done
        cmd="$1"; shift
        target=""
        for a in "$@"; do
          [ "$a" = "--" ] && continue
          target="$a"
        done
        if [ -n "$target" ] && [ -e "$target" ]; then
          mode="$(stat -c %a "$target" 2>/dev/null || echo 000)"
          other="$(printf '%s' "$mode" | tail -c1)"
          if [ $((other & 4)) -eq 0 ]; then
            echo "shim-setpriv: simulated EACCES (not world-readable) on $target" >&2
            exit 13
          fi
        fi
        exec "$cmd" "$@"
      SH
    end

    after do
      [ persist_dir, base_dir, shim_dir ].each do |d|
        FileUtils.remove_entry(d) if File.exist?(d) || File.symlink?(d)
      end
    end

    def write_shim(name, content)
      path = File.join(shim_dir, name)
      File.write(path, content)
      FileUtils.chmod(0o755, path)
    end

    def run_script
      env = {
        "POWERNODE_TRAEFIK_DYNAMIC_PERSIST_DIR" => persist_dir,
        "POWERNODE_TRAEFIK_DYNAMIC_DIR" => dst_dir,
        "PATH" => "#{shim_dir}:#{ENV.fetch('PATH')}"
      }
      Open3.capture3(env, "sh", script_path)
    end

    # World-readable (0644, "other" read bit set) — what the setpriv shim
    # treats as openable by an unprivileged reader, matching how
    # Core::IngressConfigWriter actually writes this file in production.
    def write_src(content)
      File.write(File.join(persist_dir, "00-host-login.yaml"), content)
      FileUtils.chmod(0o644, File.join(persist_dir, "00-host-login.yaml"))
    end

    it "restores a plain-file config (happy path): real file, exact content, mode 0644" do
      write_src("routers: {}\n")

      out, err, status = run_script

      expect(status.success?).to be(true), "script exited nonzero: #{err}"
      expect(out).to match(/restored 00-host-login\.yaml from/)
      expect(File.symlink?(name_file)).to be(false)
      expect(File.read(name_file)).to eq("routers: {}\n")
      expect(File.stat(name_file).mode & 0o777).to eq(0o644)
    end

    it "never chowns DST_DIR itself (that would break rails's own 2775 write access)" do
      write_src("routers: {}\n")

      run_script

      lines = File.exist?(chown_log) ? File.readlines(chown_log) : []
      expect(lines.join).not_to include(dst_dir), "DST_DIR must never be chowned — rails-setup.sh owns its 2775 mode"
    end

    it "chowns the root-only staging directory and its captured content, never a fixed name" do
      write_src("routers: {}\n")

      run_script

      lines = File.readlines(chown_log)
      staging_dir_chown = lines.find { |l| l.match?(/\Achown root:root #{Regexp.escape(base_dir)}\/\.traefik-restore\.\S+\n\z/) }
      expect(staging_dir_chown).not_to be_nil, "expected a chown on the mktemp-generated staging dir, got:\n#{lines.join}"
      content_chown = lines.find { |l| l.match?(/\Achown root:root #{Regexp.escape(base_dir)}\/\.traefik-restore\.\S+\/content\n\z/) }
      expect(content_chown).not_to be_nil, "expected a chown on the staging dir's captured content file, got:\n#{lines.join}"
    end

    # RED-FIRST, ROUND 1 GAP: a hardlink is a regular file in its own right —
    # it passes `-L`/`-f` cleanly, which is exactly what round 1's fix
    # (symlink-only) missed. Verified this example fails against round 1's
    # script (not just the pre-fix original) — see the review report.
    it "refuses a hardlink to a file the unprivileged reader cannot open, and never copies its content" do
      secret_dir = Dir.mktmpdir
      secret = File.join(secret_dir, "shadow-like-secret")
      File.write(secret, "TOP-SECRET-CONTENT\n")
      FileUtils.chmod(0o600, secret) # NOT other-readable — the shim must refuse this
      hardlink_path = File.join(persist_dir, "00-host-login.yaml")
      File.link(secret, hardlink_path)

      out, err, status = run_script

      expect(status.success?).to be(true), "this script must always exit 0 so traefik still starts"
      expect(err).to match(/could not read /)
      expect(File.exist?(name_file)).to be(false)
      expect(Dir.glob(File.join(dst_dir, "**", "*")).map { |f| File.read(f) if File.file?(f) }.compact)
        .not_to include("TOP-SECRET-CONTENT\n")
    ensure
      FileUtils.remove_entry(secret_dir) if secret_dir
    end

    it "restores a hardlink to a file the unprivileged reader CAN open (world-readable) — the fix doesn't overreach" do
      secret_dir = Dir.mktmpdir
      shared = File.join(secret_dir, "world-readable-config")
      File.write(shared, "routers: {}\n")
      FileUtils.chmod(0o644, shared)
      hardlink_path = File.join(persist_dir, "00-host-login.yaml")
      File.link(shared, hardlink_path)

      out, _err, status = run_script

      expect(status.success?).to be(true)
      expect(out).to match(/restored 00-host-login\.yaml from/)
      expect(File.read(name_file)).to eq("routers: {}\n")
    ensure
      FileUtils.remove_entry(secret_dir) if secret_dir
    end

    it "refuses a source symlinked to a file (belt-and-braces ahead of the privileged read)" do
      secret_dir = Dir.mktmpdir
      secret = File.join(secret_dir, "shadow-like-secret")
      File.write(secret, "TOP-SECRET-CONTENT\n")
      File.symlink(secret, File.join(persist_dir, "00-host-login.yaml"))

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/is a symlink/)
      expect(out).not_to match(/restored/)
      expect(File.exist?(name_file)).to be(false)
    ensure
      FileUtils.remove_entry(secret_dir) if secret_dir
    end

    it "refuses a source symlinked to a directory" do
      secret_dir = Dir.mktmpdir
      File.write(File.join(secret_dir, "inside.txt"), "dir-secret\n")
      File.symlink(secret_dir, File.join(persist_dir, "00-host-login.yaml"))

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/is a symlink/)
      expect(out).not_to match(/restored/)
      expect(File.exist?(name_file)).to be(false)
    ensure
      FileUtils.remove_entry(secret_dir) if secret_dir
    end

    it "refuses a dangling symlink source" do
      File.symlink("/does/not/exist/nowhere", File.join(persist_dir, "00-host-login.yaml"))

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/is a symlink/)
      expect(out).not_to match(/restored/)
      expect(File.exist?(name_file)).to be(false)
    end

    it "refuses a directory sitting at the source path (not a symlink, just not a regular file)" do
      FileUtils.mkdir_p(File.join(persist_dir, "00-host-login.yaml"))

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/exists but is not a regular file/)
      expect(File.exist?(name_file)).to be(false)
    end

    it "finishes promptly (does not hang the boot) and refuses a FIFO sitting at the source path" do
      require "open3"
      fifo_path = File.join(persist_dir, "00-host-login.yaml")
      system("mkfifo", fifo_path) or raise "mkfifo unavailable in this environment"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, err, status = run_script
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(status.success?).to be(true)
      expect(elapsed).to be < 5, "a FIFO source must be refused by the early type check, not reach the 10s privileged-read timeout at all"
      expect(err).to match(/exists but is not a regular file/)
      expect(File.exist?(name_file)).to be(false)
    end

    it "refuses outright when DST_DIR itself has been replaced by a symlink to somewhere OTHER than SRC_DIR" do
      other_dir = Dir.mktmpdir
      File.symlink(other_dir, dst_dir)
      write_src("routers: {}\n")

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/is a symlink to something other than the durable dir/)
      expect(Dir.glob(File.join(other_dir, "*"))).to be_empty
    ensure
      FileUtils.remove_entry(other_dir) if other_dir
    end

    # THE COMPOSED-NODE CASE (review round 2): the agent's
    # applyTraefikIngressPersistence makes DST_DIR a symlink STRAIGHT TO
    # SRC_DIR on module-composed nodes. That must be treated as "nothing to
    # restore", at INFO — not refused as an attack.
    it "treats DST_DIR being a symlink to SRC_DIR itself as the expected composed-node case: INFO, exit 0, no warning" do
      File.symlink(persist_dir, dst_dir)
      write_src("routers: {}\n")

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(out).to match(/watched dir is the durable dir/)
      expect(err).to eq(""), "the composed case must not log at WARNING"
    end

    it "refuses outright when DST_DIR's parent has been replaced by a symlink" do
      real_base = base_dir
      elsewhere = Dir.mktmpdir
      FileUtils.remove_entry(real_base)
      File.symlink(elsewhere, real_base)
      write_src("routers: {}\n")

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/#{Regexp.escape(real_base)} is a symlink/)
      expect(Dir.glob(File.join(elsewhere, "**", "*"))).to be_empty
    ensure
      FileUtils.remove_entry(elsewhere) if elsewhere
      File.delete(real_base) if real_base && File.symlink?(real_base)
    end

    it "refuses to restore when a referenced cert/key file is missing (never breaks TLS wholesale)" do
      write_src(<<~YAML)
        tls:
          options:
            default:
              clientAuth:
                caFiles:
                  - /no/such/ca.crt
      YAML

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/referenced file\(s\) missing or unreadable/)
      expect(File.exist?(name_file)).to be(false)
    end

    it "refuses a referenced cert/key file the unprivileged reader cannot open, even though root could" do
      root_readable_only_ca = File.join(persist_dir, "root-only.crt")
      File.write(root_readable_only_ca, "not really a cert\n")
      FileUtils.chmod(0o600, root_readable_only_ca) # exists, but not other-readable
      write_src(<<~YAML)
        tls:
          options:
            default:
              clientAuth:
                caFiles:
                  - #{root_readable_only_ca}
      YAML

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/referenced file\(s\) missing or unreadable/)
      expect(File.exist?(name_file)).to be(false)
    end

    it "refuses a source over the 1 MiB cap (oversized or endless source)" do
      write_src(("a" * (1024 * 1024 + 1)))

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(err).to match(/exceeds the 1048576-byte cap/)
      expect(File.exist?(name_file)).to be(false)
    end

    it "restores a source exactly at the 1 MiB cap" do
      write_src(("a" * (1024 * 1024)))

      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(out).to match(/restored 00-host-login\.yaml from/)
      expect(File.stat(name_file).size).to eq(1024 * 1024)
    end

    it "starts clean, without error, on first boot (no persisted config yet)" do
      out, err, status = run_script

      expect(status.success?).to be(true)
      expect(out).to match(/no persisted config at/)
      expect(err).to eq("")
    end

    it "removes its staging directory on exit, leaving nothing behind under DST_DIR's parent" do
      write_src("routers: {}\n")

      run_script

      leftovers = Dir.glob(File.join(base_dir, ".traefik-restore.*"))
      expect(leftovers).to be_empty, "staging dir must be cleaned up via trap: #{leftovers.inspect}"
    end

    # Review round: :213-215 forks setpriv+test ONCE PER UNIQUE referenced
    # path. A file with tens of thousands of distinct caFiles entries would
    # overrun the unit's TimeoutStartSec=30 and fail the boot-critical
    # dependency traefik's Requires= sits on. The cap must always finish
    # fast and exit 0 (never taking traefik down over a pathological input).
    it "caps referenced-path validation at 64 unique paths, refusing fast rather than forking once per path unboundedly" do
      refs = (1..100).map { |i| "/no/such/path-#{i}.crt" }
      write_src(<<~YAML)
        tls:
          options:
            default:
              clientAuth:
                caFiles:
        #{refs.map { |r| "        - #{r}" }.join("\n")}
      YAML

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, err, status = run_script
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(status.success?).to be(true)
      expect(elapsed).to be < 5, "100 referenced paths must never approach anywhere near the unit's 30s TimeoutStartSec"
      expect(err).to match(/more than 64 distinct/)
      expect(File.exist?(name_file)).to be(false)
    end

    it "still restores normally with exactly 64 unique referenced paths (the cap's own boundary)" do
      refs = (1..64).map { |i| File.join(persist_dir, "ca-#{i}.crt") }
      refs.each { |f| File.write(f, "cert #{f}\n") }
      write_src(<<~YAML)
        tls:
          options:
            default:
              clientAuth:
                caFiles:
        #{refs.map { |r| "        - #{r}" }.join("\n")}
      YAML

      out, err, status = run_script

      expect(status.success?).to be(true), "unexpected stderr: #{err}"
      expect(out).to match(/restored 00-host-login\.yaml from/)
      expect(File.exist?(name_file)).to be(true)
    end

    # Review round: in dash, `trap cleanup TERM` (no `exit` inside the
    # handler) means the handler runs and the SCRIPT CONTINUES from where it
    # was interrupted — a boot-critical unit stopped by systemd (or timing
    # out) would not actually stop, and could go on to complete the very
    # restore it was asked to abandon. Proven here by actually delivering
    # SIGTERM mid-run (during the privileged read, via the setpriv shim's
    # TEST_SETPRIV_SLEEP hook) and checking the OUTCOME, not just that a
    # trap function is textually present: the destination must never be
    # written, the staging dir must be gone, and the process must have
    # actually exited — any one of those failing would mean the script kept
    # going past the signal instead of stopping.
    it "actually terminates on SIGTERM instead of continuing past the trap (dash trap semantics)" do
      # NOTE on what "no file written" alone CANNOT prove here: this script
      # guards nearly every later step with `|| true`/`2>/dev/null`, so even
      # the BUGGY behavior (cleanup runs, then execution falls through to
      # the rest of the script with the staging dir already gone) converges
      # on the SAME externally visible outcome — no destination file, exit
      # 0 — because every subsequent operation on the now-deleted staging
      # dir just fails harmlessly and logs "restore failed". Verified
      # empirically against the pre-fix trap: elapsed time matched the FULL
      # sleep (dash defers the pending trap until the current foreground
      # child returns, it does not interrupt it), and the output contained
      # "cannot open .../content: No such file" followed by "restore
      # failed" — direct evidence execution kept running for several more
      # lines after cleanup(), not that it stopped. So the assertion that
      # actually distinguishes stop-immediately from continues-past-the-trap
      # is the ABSENCE of that later log line, not file existence.
      write_src("routers: {}\n")
      env = {
        "POWERNODE_TRAEFIK_DYNAMIC_PERSIST_DIR" => persist_dir,
        "POWERNODE_TRAEFIK_DYNAMIC_DIR" => dst_dir,
        "PATH" => "#{shim_dir}:#{ENV.fetch('PATH')}",
        "TEST_SETPRIV_SLEEP" => "2"
      }
      read, write = IO.pipe
      pid = Process.spawn(env, "sh", script_path, out: write, err: write)
      write.close

      sleep 0.4 # let it reach the sleeping setpriv shim (inside the privileged read)
      staging_dirs_during = Dir.glob(File.join(base_dir, ".traefik-restore.*"))
      Process.kill("TERM", pid)
      # NOT asserting a tight wall-clock bound here: dash only NOTICES a
      # pending trap once the current foreground child (the sleeping
      # setpriv shim) returns on its own — that is true of BOTH the buggy
      # and the fixed trap, since the fix changes what the trap DOES, not
      # when dash gets around to running it. Process.wait2 simply blocks
      # until that happens, however long it takes.
      _pid, status = Process.wait2(pid)
      output = read.read
      read.close

      expect(staging_dirs_during).not_to be_empty,
        "the signal must land while the staging dir still exists, to prove the trap (not luck) removed it"
      expect(status.exitstatus).to eq(0)
      expect(Dir.glob(File.join(base_dir, ".traefik-restore.*"))).to be_empty,
        "the EXIT trap must remove the staging dir even when triggered via TERM, not only on a normal exit"
      expect(output).not_to match(/restore failed|cannot open/),
        "the script must not continue past the TERM trap and reach later steps operating on the already-cleaned-up staging dir: #{output.inspect}"
      expect(File.exist?(name_file)).to be(false)
    end

    # Boot-safety critic, review round 4: on cloud_init-model nodes the
    # agent writes a capabilities.conf drop-in on EVERY unit in this
    # module, restore-dynamic included (CapabilityBoundingSet=
    # CAP_NET_BIND_SERVICE only) — no CAP_SETUID/CAP_SETGID, so setpriv can
    # never exec there at all ("setresuid failed: Operation not permitted",
    # exit 127). Without a fallback, round 2's setpriv-based reader would
    # ALWAYS refuse on that node class — a regression versus the pre-fix
    # script, which read as root and worked fine there. This shim always
    # exits 127 (never execs the wrapped command), simulating exactly that
    # environment, so these examples exercise the FALLBACK root read.
    describe "no-CAP_SETUID fallback (IMP-7e08f1514046 round 4)" do
      before do
        write_shim("setpriv", <<~SH)
          #!/bin/sh
          echo "setresuid failed: Operation not permitted" >&2
          exit 127
        SH
      end

      it "still restores a plain, non-hardlinked, non-symlinked source via the fallback root read" do
        write_src("routers: {}\n")

        out, err, status = run_script

        expect(status.success?).to be(true), "unexpected stderr: #{err}"
        expect(out).to match(/cannot drop privileges.*falling back to a guarded root read/)
        expect(out).to match(/restored 00-host-login\.yaml from/)
        expect(File.read(name_file)).to eq("routers: {}\n")
      end

      it "refuses a hardlinked source in the fallback (nlink check replaces the privilege-drop defense)" do
        secret_dir = Dir.mktmpdir
        secret = File.join(secret_dir, "hardlink-target")
        File.write(secret, "TOP-SECRET-HARDLINK\n")
        hardlink_path = File.join(persist_dir, "00-host-login.yaml")
        File.link(secret, hardlink_path)

        out, err, status = run_script

        expect(status.success?).to be(true)
        expect(err).to match(/hard link\(s\).*refusing a hardlinked source/)
        expect(File.exist?(name_file)).to be(false)
      ensure
        FileUtils.remove_entry(secret_dir) if secret_dir
      end

      it "still refuses a symlinked source in the fallback (the -L check runs before setpriv is ever invoked)" do
        secret_dir = Dir.mktmpdir
        secret = File.join(secret_dir, "shadow-like-secret")
        File.write(secret, "TOP-SECRET\n")
        File.symlink(secret, File.join(persist_dir, "00-host-login.yaml"))

        out, err, status = run_script

        expect(status.success?).to be(true)
        expect(err).to match(/is a symlink/)
        expect(File.exist?(name_file)).to be(false)
      ensure
        FileUtils.remove_entry(secret_dir) if secret_dir
      end

      it "still refuses a FIFO source promptly in the fallback (the early type check runs before setpriv too)" do
        fifo_path = File.join(persist_dir, "00-host-login.yaml")
        system("mkfifo", fifo_path) or raise "mkfifo unavailable in this environment"

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        out, err, status = run_script
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(status.success?).to be(true)
        expect(elapsed).to be < 5
        expect(err).to match(/exists but is not a regular file/)
        expect(File.exist?(name_file)).to be(false)
      end

      it "still refuses an oversized source in the fallback (the same 1 MiB cap applies to the retried read)" do
        write_src(("a" * (1024 * 1024 + 1)))

        out, err, status = run_script

        expect(status.success?).to be(true)
        expect(err).to match(/exceeds the 1048576-byte cap/)
        expect(File.exist?(name_file)).to be(false)
      end
    end
  end
end
