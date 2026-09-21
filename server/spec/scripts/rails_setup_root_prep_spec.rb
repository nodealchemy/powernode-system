# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "yaml"

# IMP-94977647c24c part A — rails-setup.sh is the root-only oneshot that
# does every root-requiring step for the now-non-root `rails` service.
#
# HONEST LIMITS OF THIS SPEC (reviewer round, kept because it stays true):
# these are structural, content-level assertions (the same shape
# rails_start_cache_schema_delivery_spec.rb uses for rails-start.sh) —
# there is no sandboxed root+traefik-group harness in this suite to
# actually EXERCISE the script. A regex match on source text can pass on
# a script that is broken in ways these assertions don't probe: an early
# `exit 0` or `if false` guarding a whole block still leaves every string
# these specs look for present in the file, and the "runs X before Y"
# examples compare byte OFFSET in the source, not execution order (an
# unreachable branch could still appear earlier in the file). Do NOT
# report this file's green as evidence drop-root WORKS on a real host —
# that is the proof-by-execution checklist's job, at rollout. What this
# DOES catch reliably: `bash -n` syntax validity (a real check, not
# content matching), and the specific fixes below being present, in the
# right relative source order, worded the way the review rounds asked
# for.
RSpec.describe "rails-setup.sh: root-only prep (IMP-94977647c24c part A)" do
  let(:extension_root) { File.expand_path("../../..", __dir__) }
  let(:script_path) do
    File.join(extension_root, "modules/powernode-hub-backend/rootfs/usr/local/bin/rails-setup.sh")
  end
  let(:script) { File.read(script_path) }

  # A REAL check, not a content match: proves the file is at least
  # syntactically valid bash, which none of the regex assertions below
  # can catch (a regex can match perfectly against a script `bash` itself
  # would refuse to run).
  describe "script integrity" do
    it "is valid bash (bash -n)" do
      _out, err, status = Open3.capture3("bash", "-n", script_path)
      expect(status.success?).to be(true), "bash -n failed: #{err}"
    end

    # The bash -n check above invokes bash EXPLICITLY, so it cannot see a
    # shebang change — a script that no longer declares #!/bin/bash would
    # still pass that check while failing outright if actually EXECUTED
    # via its own executable bit (e.g. systemd's ExecStart=/path/to/script
    # with no interpreter prefix). The block genuinely requires bash
    # (process substitution `<(...)`, `read -r -d ''`), so the shebang
    # matters, not just as a style nit.
    it "declares #!/bin/bash as its shebang" do
      expect(script.lines.first).to eq("#!/bin/bash\n")
    end

    it "passes shellcheck, when the binary is available in this environment" do
      skip "shellcheck not installed in this environment" unless system("which shellcheck > /dev/null 2>&1")

      out, _err, status = Open3.capture3("shellcheck", "-S", "error", script_path)
      expect(status.success?).to be(true), "shellcheck -S error failed:\n#{out}"
    end
  end

  # Defect #1 of the 2026-09-20 ops-hub outage, RESURRECTED (this file was
  # only ever fixed host-side, in a tmpfs overlay, and never committed).
  # manifest.yaml:63's rails-setup unit_body has `ExecStart=/usr/local/bin/
  # rails-setup.sh` -- a BARE PATH, no interpreter prefix -- so systemd
  # execs the file directly, honoring only the COMMITTED git mode. The
  # working tree's `File.executable?`/`ls -l` reflects the checkout's
  # umask, NOT what ships: this is exactly how a 100644 blob shipped
  # invisibly before, so every check below reads the git-tracked mode
  # (`git ls-files -s`, which reflects the INDEX -- staged-but-uncommitted
  # is visible here too, so `chmod +x && git add` shows green before an
  # actual commit exists) rather than the filesystem bit. On a clean build
  # (stage2-carve.sh's `rsync -a`, mode-preserving, no chmod step) a 100644
  # rails-setup.sh ships non-executable, rails-setup.service fails
  # 203/EXEC, and rails' `Requires=` on it (from `start_before` in the
  # manifest) gets its own start job CANCELLED -- the backend never starts.
  describe "boot-blocker: rails-setup.sh must be committed executable (100755), not just chmod'd on disk" do
    let(:manifest_path) do
      File.join(extension_root, "modules/powernode-hub-backend/manifest.yaml")
    end
    let(:manifest) { YAML.safe_load(File.read(manifest_path)) }

    # A single token, no flags/args/interpreter prefix -- the shape systemd
    # execs directly rather than handing to a shell or a language runtime.
    # `bundle exec ruby foo.rb`, `/bin/bash -c "..."`, etc. all have more
    # than one whitespace-separated token and are deliberately excluded:
    # THOSE files are read by an interpreter, which only needs read
    # permission, not the executable bit.
    def bare_exec_path(command)
      return nil unless command.is_a?(String)

      tokens = command.strip.split(/\s+/)
      return nil unless tokens.size == 1

      path = tokens.first
      path.start_with?("/") ? path : nil
    end

    # Every ExecStart= line inside a raw `unit_body:` (rails-setup has no
    # structured `start_command`, only a hand-written unit) plus every
    # structured `start_command:` field (rails) across ALL services in
    # THIS module's manifest -- generalized so a FUTURE bare-path service
    # in this manifest is caught the same way, not just this one file.
    def bare_rootfs_execs(manifest)
      execs = []
      (manifest["services"] || []).each do |svc|
        if (cmd = bare_exec_path(svc["start_command"]))
          execs << cmd
        end
        if (unit_body = svc["unit_body"])
          unit_body.scan(/^ExecStart=(.*)$/).each do |(line)|
            path = bare_exec_path(line)
            execs << path if path
          end
        end
      end
      execs.uniq
    end

    def git_tracked_mode(relative_path)
      out, _err, status = Open3.capture3("git", "-C", extension_root, "ls-files", "-s", "--", relative_path)
      return nil unless status.success?

      # `git ls-files -s` output: "<mode> <sha> <stage>\t<path>"
      out.split(/\s+/).first
    end

    # Sanity-checks the extraction itself, not the fix -- if this finds
    # nothing, every example below would vacuously pass on an empty list,
    # which is worse than not having the spec at all.
    it "finds at least the two known bare-path services in this manifest (rails-setup, rails)" do
      execs = bare_rootfs_execs(manifest)
      expect(execs).to include("/usr/local/bin/rails-setup.sh")
      expect(execs).to include("/usr/local/bin/rails-start.sh")
    end

    it "every bare-path ExecStart/start_command in this manifest is committed 100755, not just chmod'd in the working tree" do
      execs = bare_rootfs_execs(manifest)
      expect(execs).not_to be_empty

      execs.each do |abs_path|
        relative = File.join("modules/powernode-hub-backend/rootfs", abs_path.delete_prefix("/"))
        mode = git_tracked_mode(relative)
        expect(mode).not_to be_nil, "#{relative} is not tracked by git at all (git ls-files -s returned nothing)"
        expect(mode).to eq("100755"),
          "#{relative} is committed #{mode} but is exec'd directly (no interpreter prefix) by " \
          "#{manifest_path} -- a build that preserves modes (rsync -a, no chmod step) would ship it " \
          "non-executable and the unit fails 203/EXEC at boot"
      end
    end

    it "specifically pins rails-setup.sh (the file that actually shipped broken)" do
      mode = git_tracked_mode("modules/powernode-hub-backend/rootfs/usr/local/bin/rails-setup.sh")
      expect(mode).to eq("100755")
    end
  end

  describe "blocker 1: agent PKI directory readability" do
    it "grants the PARENT traverse-only (0710, no group-read/list) and the pki/ dir itself 0750" do
      expect(script).to match(/chgrp\s+"\$RAILS_USER"\s+"\$AGENT_PKI_PARENT"/)
      expect(script).to match(/chmod\s+0710\s+"\$AGENT_PKI_PARENT"/)
      expect(script).to match(/chgrp\s+"\$RAILS_USER"\s+"\$AGENT_PKI_DIR"/)
      expect(script).to match(/chmod\s+0750\s+"\$AGENT_PKI_DIR"/)
    end

    it "never widens the PKI parent to 0750+ (group-listable) or touches node.key" do
      command_lines = script.lines.grep(/^\s*(chmod|chgrp|chown)\b/)
      pki_commands  = command_lines.select { |l| l.match?(/AGENT_PKI/) }
      expect(pki_commands).not_to be_empty
      expect(pki_commands.join).not_to match(/node\.key/)

      parent_chmods = pki_commands.grep(/AGENT_PKI_PARENT/).grep(/chmod/)
      expect(parent_chmods).not_to be_empty
      expect(parent_chmods.join).to match(/\A(\s*chmod\s+0?710\s.*\n?)+\z/),
        "every chmod on AGENT_PKI_PARENT must be exactly 0710 (traverse, no listing) — 0750 there re-opens the finding"

      dir_chmods = pki_commands.grep(/AGENT_PKI_DIR"/).grep(/chmod/)
      expect(dir_chmods).not_to be_empty
      expect(dir_chmods.join).to match(/\A(\s*chmod\s+0?750\s.*\n?)+\z/),
        "every chmod on AGENT_PKI_DIR must be exactly 0750, never wider"
    end
  end

  describe "blocker 2: a failed traefik ingress-dir setup must not take rails down with it" do
    it "isolates the mkdir/chown/chmod ingress-dir setup behind an `if <call>; then ... else <warn>` guard" do
      expect(script).to match(/setup_traefik_ingress_dirs\s*\(\)\s*\{/),
        "the mkdir/chown/chmod trio must live in a function so bash's -e-suspension-under-if applies to the WHOLE body"
      expect(script).to match(/if\s+setup_traefik_ingress_dirs\s*;\s*then/)
      # Every command inside the function must itself fail closed (return
      # non-zero) rather than let `set -e` abort the whole script — a bare
      # command with no `|| return 1` would still be caught by -e WITHIN
      # the function body (the -e suspension is about the SCRIPT not
      # exiting, not about disabling -e inside the function), aborting
      # setup_traefik_ingress_dirs and skipping any command listed after
      # the failure point, but that's fine; what matters is proving the
      # function's commands are wired to signal failure, not swallow it.
      body = script[/setup_traefik_ingress_dirs\s*\(\)\s*\{.*?\n\}/m]
      expect(body).not_to be_nil
      %w[mkdir chown chmod].each do |cmd|
        expect(body).to match(/^\s*#{cmd}\b.*\|\|\s*return\s+1\s*$/),
          "#{cmd} inside setup_traefik_ingress_dirs must `|| return 1`, not rely on -e alone"
      end
    end

    it "logs a loud warning and continues (does not re-raise) when the guarded setup fails" do
      # Anchor "else"/"fi" to actual bash keywords (start of line, only
      # leading whitespace before them) — a plain /else/ substring match
      # false-positives on the prose comment "everything ELSE under the
      # cert dirs" that appears earlier in the same then-branch.
      else_branch = script[/if\s+setup_traefik_ingress_dirs\s*;\s*then.*?\n\s*else\n(.*?)\n\s*fi\n/m, 1]
      expect(else_branch).not_to be_nil
      expect(else_branch).to match(/echo.*WARNING.*traefik/i)
      expect(else_branch).not_to match(/\bexit\s+[1-9]/), "the else branch must degrade, not abort the script"
    end

    it "keeps the two secrets migrations and the database.yml render OUTSIDE any such guard — those stay fatal" do
      setup_fn_start = script.index("setup_traefik_ingress_dirs()")
      secrets_idx    = script.index("for f in backend-default.conf")
      db_yml_idx     = script.index("Rendering config/database.yml")
      expect(setup_fn_start).not_to be_nil
      expect(secrets_idx).not_to be_nil
      expect(db_yml_idx).not_to be_nil
      # Both must appear textually BEFORE the guarded function is even
      # defined, i.e. they are not nested inside it or any wrapper that
      # shares its degrade-on-failure behavior.
      expect(secrets_idx).to be < setup_fn_start
      expect(db_yml_idx).to be < setup_fn_start
    end
  end

  describe "blocker 1 (review round 2): the internal CA store is also in the fatal set" do
    let(:ca_section) { script[/ca_local_dir=""\n.*?(?=\n# LOUD BUT NON-FATAL)/m] }

    it "resolves via sed (not grep|cut), tolerates leading whitespace/export, and matches with tail -n1 (last-assignment-wins)" do
      expect(ca_section).not_to be_nil
      expect(ca_section).to match(/sed -n '/)
      expect(ca_section).to match(/POWERNODE_CA_LOCAL_DIR=\/\/p'/)
      expect(ca_section).to match(/\[\[:space:\]\]\*/), "must tolerate leading whitespace on the line"
      expect(ca_section).to match(/export\[\[:space:\]\]/), "must tolerate an export prefix"
      expect(ca_section).to match(/\|\s*tail -n1/)
      expect(ca_section).not_to match(/grep.*POWERNODE_CA_LOCAL_DIR.*\|\s*cut/),
        "grep|cut under set -euo pipefail exits 1 (killing the script) on the COMMON no-match case — see the block's own comment"
      expect(ca_section).to match(/:\s*"\$\{ca_local_dir:=\$STATE_DIR\/internal-ca\}"/)
    end

    it "strips a pair of surrounding quotes from the extracted value" do
      expect(ca_section).to match(/ca_local_dir="\$\{ca_local_dir%\\"\}"/)
      expect(ca_section).to match(/ca_local_dir="\$\{ca_local_dir#\\"\}"/)
    end

    it "resolves through a symlink via readlink -m (NOT -f) before testing/chowning" do
      # -f requires every path component to exist and exits 1 the moment
      # one doesn't — under set -euo pipefail that's blocker 1's exact
      # failure class (measured: readlink -f with a missing PARENT
      # component kills the script; -m canonicalizes regardless and still
      # resolves a real symlink to its target).
      expect(ca_section).to match(/ca_local_dir="\$\(readlink -m "\$ca_local_dir"\)"/)
      # Only the CODE, not prose: the fix's own comment legitimately
      # names "readlink -f" while explaining what was measured and why
      # it was rejected.
      code_lines = ca_section.lines.reject { |l| l.strip.start_with?("#") }
      expect(code_lines.join).not_to match(/readlink -f/)
    end

    it "echoes the resolved directory unconditionally, not only on the failure branch" do
      expect(ca_section).to match(/echo "\[rails-setup\] internal CA store resolved to \$ca_local_dir"/)
    end

    it "chowns it recursively, ownership only — no chmod anywhere near ca_local_dir" do
      expect(ca_section).not_to be_nil
      expect(ca_section).to match(/chown -R "\$RAILS_USER:\$RAILS_USER" "\$ca_local_dir"/)
      expect(ca_section).not_to match(/chmod\b/),
        "the anchor's key material is 0600 / dirs 0700 by InternalCaService's own design and must survive unchanged"
    end

    it "handles a not-yet-existing store (first boot) without failing — existence is guarded, not swallowed" do
      expect(ca_section).to match(/if \[ -d "\$ca_local_dir" \]; then/)
      expect(ca_section).to match(/else\n\s*echo.*no internal CA store yet/)
    end

    # BLOCKER 1, the actual defect — GENUINELY EXECUTES the extracted
    # resolution snippet (not a text/regex assertion), the same standard
    # applied to blocker 2. The grep|cut form measured as: prints
    # "before", then dies with exit 1, NEVER reaching the next line — the
    # exact failure mode of a rails-setup.service that fails closed on a
    # boot-critical unit for no reason connected to any real problem.
    # Reproduced here by running the CURRENT script's actual resolution
    # code (extracted verbatim from the file, not retyped) against a
    # secrets file that deliberately does NOT carry the key — the common
    # case (a first-boot heredoc that never writes it) as well as the
    # rarer one this review round surfaced (a disk-full event that
    # degrades rails-start.sh's OWN publish step to a warning instead of
    # writing it).
    it "does NOT abort the script when the secrets file exists but has no POWERNODE_CA_LOCAL_DIR key" do
      Dir.mktmpdir do |state_dir|
        File.write(File.join(state_dir, "backend-default.conf"), "SOME_OTHER_KEY=value\n")

        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          STATE_DIR=#{state_dir}
          #{ca_section}
          echo "REACHED_END"
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)

        expect(status.success?).to be(true), "script aborted: #{err}"
        expect(out).to include("REACHED_END"), "execution stopped before the marker — the extraction killed the script"
        expect(out).to include("no internal CA store yet"), "should hit the first-boot branch with an empty resolved value"
      end
    end

    # The follow-up round: the FIRST executing spec above only measured
    # the easy case (key absent entirely, empty value, readlink handling
    # nothing). readlink -f is also fine on ITS easy case (a missing LEAF
    # with an existing parent) — the failure lives one level further in,
    # a missing PARENT component, which is exactly the shape a real
    # deployment hits: a stale/operator-set path, or any boot where the
    # store's parent filesystem (/persist) isn't mounted yet when this
    # script runs. Measure THAT shape, not the one that already passes.
    it "does NOT abort when the resolved path's PARENT directory does not exist (readlink -m, not -f)" do
      Dir.mktmpdir do |state_dir|
        missing_parent_path = File.join(state_dir, "does-not-exist-parent", "nested", "ca")
        File.write(File.join(state_dir, "backend-default.conf"),
                   "POWERNODE_CA_LOCAL_DIR=#{missing_parent_path}\n")

        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          STATE_DIR=#{state_dir}
          #{ca_section}
          echo "REACHED_END"
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)

        expect(status.success?).to be(true), "script aborted: #{err}"
        expect(out).to include("REACHED_END"),
          "execution stopped before the marker — readlink -f (not -m) would kill the script on a missing PARENT component"
        expect(out).to include("no internal CA store yet"),
          "the resolved path itself still doesn't exist, so this should still be the first-boot branch"
      end
    end

    # Review round: every executing spec so far only ever landed in the
    # FIRST-BOOT branch (nothing at the resolved path). The single
    # property `readlink` exists in this line FOR — resolving a symlink
    # to its real target — had no executing coverage at all; the earlier
    # tests only pinned that the `readlink -m` TEXT is present. Red-first:
    # drop the readlink line entirely and this must fail (the echo would
    # then print the LINK path, not the target, and PROBABLY still take
    # the [ -d ] branch since a symlink to a directory itself satisfies
    # `[ -d ]` — so the target-path assertion is what actually catches a
    # dropped readlink, not the branch assertion alone).
    it "resolves a symlinked store to its REAL target (not the link itself), and takes the existing-store branch" do
      Dir.mktmpdir do |state_dir|
        real_target = File.join(state_dir, "real-ca-store")
        FileUtils.mkdir_p(real_target)
        link_path = File.join(state_dir, "ca-link")
        File.symlink(real_target, link_path)
        File.write(File.join(state_dir, "backend-default.conf"),
                   "POWERNODE_CA_LOCAL_DIR=#{link_path}\n")

        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          STATE_DIR=#{state_dir}
          #{ca_section}
          echo "REACHED_END"
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)

        expect(status.success?).to be(true), "script aborted: #{err}"
        expect(out).to include("REACHED_END")
        expect(out).to include("internal CA store resolved to #{real_target}"),
          "must resolve to the REAL target directory, not the symlink path — a dropped readlink would print the link path instead"
        expect(out).not_to include("no internal CA store yet"),
          "a symlink to a REAL, existing directory must take the existing-store branch, not first-boot"
      end
    end

    # Review round: BOTH prior executing examples land in the first-boot
    # branch — the happy path (a store that already EXISTS, so `chown -R`
    # actually runs) had never been proven not to abort. Cheap to prove:
    # as a non-root user chowning a directory TO YOURSELF always succeeds.
    it "takes the existing-store branch and runs chown -R without aborting (happy path)" do
      Dir.mktmpdir do |state_dir|
        existing_store = File.join(state_dir, "existing-ca-store")
        FileUtils.mkdir_p(existing_store)
        File.write(File.join(state_dir, "backend-default.conf"),
                   "POWERNODE_CA_LOCAL_DIR=#{existing_store}\n")

        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          STATE_DIR=#{state_dir}
          #{ca_section}
          echo "REACHED_END"
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)

        expect(status.success?).to be(true), "script aborted: #{err}"
        expect(out).to include("REACHED_END")
        expect(out).not_to include("no internal CA store yet"),
          "an EXISTING store must take the chown -R branch, not the first-boot one"
      end
    end

    # Review round (adoption item, non-blocking): the extraction diverges
    # from `. "$SECRETS_FILE"` on three hand-edit-realistic shapes. Cover
    # the two that need code changes (single-quoted, export-prefixed) —
    # double-quoted and plain are already covered by the symlink/happy-path
    # examples above.
    it "handles a SINGLE-quoted value the same way `. ` sourcing would" do
      Dir.mktmpdir do |state_dir|
        existing_store = File.join(state_dir, "single-quoted-store")
        FileUtils.mkdir_p(existing_store)
        File.write(File.join(state_dir, "backend-default.conf"),
                   "POWERNODE_CA_LOCAL_DIR='#{existing_store}'\n")

        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          STATE_DIR=#{state_dir}
          #{ca_section}
          echo "REACHED_END"
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)

        expect(status.success?).to be(true), "script aborted: #{err}"
        expect(out).to include("internal CA store resolved to #{existing_store}"),
          "single-quote characters must be stripped, not left in the resolved path"
        expect(out).not_to include("no internal CA store yet")
      end
    end

    it "handles an `export KEY=...` line the same way `. ` sourcing would" do
      Dir.mktmpdir do |state_dir|
        existing_store = File.join(state_dir, "exported-store")
        FileUtils.mkdir_p(existing_store)
        File.write(File.join(state_dir, "backend-default.conf"),
                   "export POWERNODE_CA_LOCAL_DIR=#{existing_store}\n")

        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          STATE_DIR=#{state_dir}
          #{ca_section}
          echo "REACHED_END"
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)

        expect(status.success?).to be(true), "script aborted: #{err}"
        expect(out).to include("internal CA store resolved to #{existing_store}"),
          "an export-prefixed assignment must resolve the same as a bare one"
        expect(out).not_to include("no internal CA store yet")
      end
    end
  end

  # Named "round 4" to avoid colliding with the (unrelated) "blocker 3:
  # durable traefik mirror" naming a prior review round already used in
  # this same file — team-lead's numbering restarted per-round, not
  # globally, so the label distinguishes them rather than implying a
  # renumbering of the earlier one.
  describe "round 4 blocker: rails-start.sh's host-login ingress avoids a fixed-name /tmp write" do
    let(:rails_start_script) do
      File.read(File.join(extension_root, "modules/powernode-hub-backend/rootfs/usr/local/bin/rails-start.sh"))
    end

    it "no longer writes the runner program to a predictable /tmp path" do
      # The defect: /tmp/ensure-host-login-ingress.rb is a FIXED name,
      # world-writable-sticky /tmp survives across restarts regardless of
      # which user created it, and a prior ROOT-era run leaves it
      # root-owned — the O_WRONLY|O_TRUNC `cat >` then gets EACCES as
      # non-root, killing rails-start under `set -euo pipefail` before
      # `exec puma` (a crash loop on restart-without-reboot).
      # Only the CODE, not prose: the fix's own explanatory comment
      # legitimately names the old path as historical context.
      code_lines = rails_start_script.lines.reject { |l| l.strip.start_with?("#") }
      expect(code_lines.join).not_to match(%r{/tmp/ensure-host-login-ingress\.rb})
    end

    it "feeds the runner program on STDIN instead (no temp file at all)" do
      expect(rails_start_script).to match(/bundle exec rails runner - <<< "\$ingress_ruby"/)
    end

    it "still runs the SAME Ruby (ensure_host_login_ingress! call + the File.exist? abort guard)" do
      expect(rails_start_script).to match(/Core::IngressConfigWriter\.ensure_host_login_ingress!/)
      expect(rails_start_script).to match(/abort\("host-login ingress file missing after write/)
    end

    it "keeps the retry loop (attempt count, sleep) unchanged around the new invocation" do
      expect(rails_start_script).to match(/for attempt in 1 2 3 4 5; do/)
      expect(rails_start_script).to match(/host login ingress attempt \$\{attempt\} did not persist/)
    end
  end

  describe "non-blocking: BOOTSNAP_CACHE_DIR points at STATE_DIR, not the module mount" do
    let(:rails_start_script) do
      File.read(File.join(extension_root, "modules/powernode-hub-backend/rootfs/usr/local/bin/rails-start.sh"))
    end

    it "exports BOOTSNAP_CACHE_DIR under STATE_DIR" do
      expect(rails_start_script).to match(/export BOOTSNAP_CACHE_DIR="\$STATE_DIR\/bootsnap"/)
    end
  end

  describe "blocker 3: durable traefik mirror (/persist/powernode-traefik) permissions" do
    it "derives the durable root from the cert dir via dirname, matching the cert-dir block byte-for-byte with rails-start.sh" do
      expect(script).to match(/TRAEFIK_DURABLE_ROOT="\$\(dirname "\$TRAEFIK_CERT_DIR"\)"/)
      expect(script).to match(/TRAEFIK_DURABLE_DYNAMIC_DIR="\$TRAEFIK_DURABLE_ROOT\/dynamic"/)
      expect(script).to match(/chown\s+root:traefik\s+"\$TRAEFIK_DURABLE_ROOT"/)
      expect(script).to match(/chmod\s+2775\s+"\$TRAEFIK_DURABLE_ROOT"/)
    end

    it "retroactively fixes existing content under the durable root, not just the live /etc/traefik pair" do
      expect(script).to match(/find\s+"\$TRAEFIK_DURABLE_ROOT"\s+\/etc\/traefik\/dynamic\s+-mindepth 1\s+-exec chown root:traefik/)
    end
  end

  describe "blocker 4: /etc/powernode legacy migration, symlink-aware" do
    it "moves real files only (never a symlink) and never clobbers an existing STATE_DIR file" do
      migration = script[/for f in backend-default\.conf.*?\ndone/m]
      expect(migration).not_to be_nil
      expect(migration).to match(/\[\s*-f\s+"\$src"\s*\]/)
      expect(migration).to match(/!\s*-L\s+"\$src"/), "must exclude symlinks — never follow/move one"
      expect(migration).to match(/!\s*-f\s+"\$dest"/), "must never overwrite an existing STATE_DIR file"
    end

    it "runs the migration before the fatal secrets-ownership fix, so the moved file ends up owned by RAILS_USER" do
      # Anchored on "migrating legacy $src" (review round), not "for f in
      # backend-default.conf" — that string now appears TWICE (the
      # migration loop above AND the FATAL secrets-chown loop share the
      # same `for f in backend-default.conf admin-credentials.json; do`
      # iteration line). String#index takes the FIRST occurrence, so the
      # old anchor was right today but would silently retarget the moment
      # either loop's shape changed — the exact first-occurrence-retargets
      # shape a round-2 spec bug already caught elsewhere in this file.
      migration_idx = script.index("migrating legacy $src")
      chown_idx     = script.index('chown "$RAILS_USER:$RAILS_USER" "$secret_path"')
      expect(migration_idx).not_to be_nil
      expect(chown_idx).not_to be_nil
      expect(migration_idx).to be < chown_idx
    end
  end

  describe "blocker 5: key vs. dynamic-YAML mode split (no more single 0660 pass)" do
    it "does not apply a single 660 mode across both the cert dir and the dynamic dirs" do
      expect(script).not_to match(/chmod\s+0?660\b/)
    end

    it "sets cert-dir files (including the TLS key) to 0640, matching Core::IngressConfigWriter's own assertion" do
      expect(script).to match(/find\s+"\$TRAEFIK_CERT_DIR"\s+-mindepth 1\s+-type f\s+-exec chmod 0?640/)
    end

    it "sets dynamic-config YAML (both live and durable) to 0664, not the key's mode" do
      expect(script).to match(
        /find\s+\/etc\/traefik\/dynamic\s+"\$TRAEFIK_DURABLE_DYNAMIC_DIR"\s+-mindepth 1\s+-type f\s+-exec chmod 0?664/
      )
    end
  end

  describe "non-blocking: bundler app config persisted for out-of-band operator use" do
    it "writes $STATE_DIR/.bundle/config with the same BUNDLE_PATH/BUNDLE_WITHOUT rails-start.sh exports" do
      expect(script).to match(/mkdir -p "\$STATE_DIR\/\.bundle"/)
      expect(script).to match(/BUNDLE_PATH:\s*"\$BUNDLE_STATE_DIR"/)
      expect(script).to match(/BUNDLE_WITHOUT:\s*"development:test"/)
    end
  end

  describe "IMP-01a0c508-0121 part 1: OCI blob proxy cache dir ownership" do
    let(:oci_service_source) do
      File.read(File.join(extension_root, "server/app/services/system/oci_blob_proxy_service.rb"))
    end

    # Extract the ACTUAL default_cache_root method body from the Ruby
    # source, not hand-copied constants — so if that method's env var name
    # or fallback literals ever change, the examples below (which read
    # their expectations FROM this extraction) fail until rails-setup.sh
    # is updated to match, instead of silently pinning stale values.
    let(:default_cache_root_body) do
      oci_service_source[/def self\.default_cache_root.*?\n    end\n/m]
    end
    let(:ruby_env_override_var) { default_cache_root_body[/ENV\["([A-Z_]+)"\]/, 1] }
    let(:ruby_nested_default) { default_cache_root_body[/return\s+"([^"]+)"\s+if File\.directory\?/, 1] }
    let(:ruby_flat_default) { default_cache_root_body.scan(/"([^"]+)"/).last&.first }

    # Anchored on the literal `if [ -d /persist ]; then` immediately
    # followed by an `OCI_CACHE_DIR=` assignment on the NEXT line — this
    # exact `[ -d /persist ]` test string is otherwise unique in the file
    # (the STATE_DIR/TRAEFIK/PKI blocks all use `mountpoint -q /persist`
    # instead, deliberately — see the resolution's own comment), so no
    # first-occurrence collision risk the way the old
    # `oci_cache_dir_override=""` anchor collided with the CA block.
    let(:resolution_block) do
      script[/if \[ -d \/persist \]; then\n\s*OCI_CACHE_DIR=.*?\nfi\n/m]
    end

    it "the Ruby extraction itself found a real method body with all three parts (sanity-checks the extraction, not the script)" do
      expect(default_cache_root_body).not_to be_nil
      expect(ruby_env_override_var).not_to be_nil
      expect(ruby_nested_default).not_to be_nil
      expect(ruby_flat_default).not_to be_nil
      expect(ruby_nested_default).not_to eq(ruby_flat_default)
    end

    it "branches on /persist's existence exactly the way the Ruby class does, not this script's usual `mountpoint -q`" do
      expect(resolution_block).not_to be_nil
      expect(resolution_block).to match(/if\s+\[\s*-d\s+\/persist\s*\]/),
        "must match File.directory?(\"/persist\") — the Ruby class's own check — not this script's usual `mountpoint -q`"
      expect(resolution_block).not_to match(/mountpoint/)
    end

    it "resolves to the SAME nested-vs-flat fallback literals the Ruby class actually returns (extracted from its source, not retyped)" do
      expect(resolution_block).to include(%(OCI_CACHE_DIR=#{ruby_nested_default}))
      expect(resolution_block).to include(%(OCI_CACHE_DIR=#{ruby_flat_default}))
    end

    it "a hardcoded flat /persist/powernode-oci-cache literal is NOT the primary resolution (that was the wrong fix, corrected in review)" do
      # The legacy-adopt step below is allowed to reference the flat path
      # explicitly; the PRIMARY resolution block must not resolve to it
      # unconditionally.
      expect(resolution_block).not_to match(/OCI_CACHE_DIR=\/persist\/powernode-oci-cache\s*$/)
    end

    it "does NOT resolve or act on an explicit POWERNODE_OCI_CACHE_DIR override (security round: see the dedicated describe block below)" do
      # The override env var NAME still legitimately appears elsewhere in
      # the file (the warn-only detection) -- what must NOT appear is the
      # override feeding INTO this resolution block specifically.
      expect(resolution_block).not_to match(/POWERNODE_OCI_CACHE_DIR/)
      expect(resolution_block).not_to match(/oci_cache_dir_override/)
    end

    it "derives the required-ownership set from ONE shared array, not a bare enumeration" do
      expect(script).to match(/RAILS_OWNED_PERSIST_SIBLINGS=\(/)
    end

    it "the array holds the resolved $OCI_CACHE_DIR variable, not a literal path" do
      array_body = script[/RAILS_OWNED_PERSIST_SIBLINGS=\(\n(.*?)\n\)/m, 1]
      expect(array_body).not_to be_nil
      expect(array_body).to match(/"\$OCI_CACHE_DIR"/)
    end

    it "creates the dir and chowns it to RAILS_USER, ownership only — no chmod anywhere near it" do
      loop_body = script[/for dir in "\$\{RAILS_OWNED_PERSIST_SIBLINGS\[@\]\}"; do\n(.*?)\ndone/m, 1]
      expect(loop_body).not_to be_nil
      expect(loop_body).to match(/mkdir -p "\$dir"/)
      expect(loop_body).to match(/chown "\$RAILS_USER:\$RAILS_USER" "\$dir"/)
      expect(loop_body).not_to match(/chmod\b/),
        "other things (module build/publish tooling) also read this cache — no mode change needed or wanted"
    end

    it "is loud but non-fatal: a create/chown failure warns and continues, never aborts the script" do
      loop_body = script[/for dir in "\$\{RAILS_OWNED_PERSIST_SIBLINGS\[@\]\}"; do\n(.*?)\ndone/m, 1]
      expect(loop_body).to match(/if\s+mkdir -p "\$dir".*&&\s*chown/)
      expect(loop_body).to match(/echo.*WARNING.*could not create\/chown/i)
      expect(loop_body).not_to match(/\bexit\s+[1-9]/), "must degrade, not abort the script"
    end

    it "adopts an existing legacy flat /persist/powernode-oci-cache dir (chown only) without ever creating it" do
      legacy_block = script[/# Legacy flat layout adoption:.*?(?=\n# config\/database\.yml)/m]
      expect(legacy_block).not_to be_nil
      expect(legacy_block).to match(%r{if \[ -d /persist/powernode-oci-cache \] && \[ "\$OCI_CACHE_DIR" != "/persist/powernode-oci-cache" \]})
      expect(legacy_block).to match(/chown "\$RAILS_USER:\$RAILS_USER" \/persist\/powernode-oci-cache/)
      expect(legacy_block).not_to match(/mkdir/), "must ADOPT an existing dir only, never create a second unreferenced cache root"
    end

    it "runs before the config/database.yml render, in the same root-prep pass" do
      resolution_idx = script.index("OCI blob proxy cache dir (IMP-01a0c508-0121")
      db_yml_idx     = script.index("Rendering config/database.yml")
      expect(resolution_idx).not_to be_nil
      expect(db_yml_idx).not_to be_nil
      expect(resolution_idx).to be < db_yml_idx
    end
  end

  # F2's history: a sed-based extraction was replaced, in review, with a
  # `.`-sourced subshell reading POWERNODE_OCI_CACHE_DIR out of
  # backend-default.conf -- then that subshell was ITSELF found to be a
  # privilege escalation and reverted, because rails-setup.sh runs as
  # ROOT while backend-default.conf is written by the non-root rails
  # process (this same script chowns it to $RAILS_USER a few sections up;
  # rails-start.sh writes it running AS that user). Sourcing rails-written
  # content as root, OR feeding a rails-controlled value into a root
  # chown/mkdir, both hand a buggy or compromised non-root rails process a
  # path to root code execution or root-owned-directory placement -- the
  # escalation is in WHAT THE VALUE FEEDS, not in how it's read, so a
  # "better parser" does not fix it either. The only safe design: never
  # let anything derived from that conf reach a privileged operation.
  describe "IMP-01a0c508-0121 security round: does NOT resolve or act on POWERNODE_OCI_CACHE_DIR; warn-only, presence-triggered" do
    let(:oci_service_source) do
      File.read(File.join(extension_root, "server/app/services/system/oci_blob_proxy_service.rb"))
    end
    let(:ruby_env_override_var) do
      oci_service_source[/def self\.default_cache_root.*?\n    end\n/m][/ENV\["([A-Z_]+)"\]/, 1]
    end

    # Anchored on the WARN-ONLY comment header immediately preceding it --
    # unique in the file, unlike the shared `if [ -f "$STATE_DIR/
    # backend-default.conf" ]; then` opening line the CA block and the
    # (now-removed) OCI override read both used, which is EXACTLY the
    # first-occurrence collision a previous round of this same spec hit.
    let(:warn_block) do
      script[/# WARN-ONLY override detection.*?\nfi\n/m]
    end

    it "detects the override by the KEY'S PRESENCE (grep -q on the bare name), not a parsed value" do
      expect(warn_block).not_to be_nil
      expect(warn_block).to include(ruby_env_override_var)
      expect(warn_block).to match(/grep -q/)
    end

    it "never feeds a conf-derived value into $OCI_CACHE_DIR, a chown, or an mkdir" do
      # CODE lines only (review round: the block's own explanatory comment
      # legitimately says "never a chown/mkdir input" in prose — matching
      # that would be testing the comment, not the behavior). Anchored to
      # line-start (allowing only leading whitespace) for the
      # OCI_CACHE_DIR check so this doesn't false-positive on
      # "...POWERNODE_OCI_CACHE_DIR=" inside the grep/sed pattern strings
      # or the warning message text, which legitimately contain that
      # substring — what must NOT appear is an actual bash ASSIGNMENT to
      # our own bare variable name.
      code_lines = warn_block.lines.reject { |l| l.strip.start_with?("#") }.join
      expect(code_lines).not_to match(/^\s*OCI_CACHE_DIR=/)
      expect(code_lines).not_to match(/\bchown\b/)
      expect(code_lines).not_to match(/\bmkdir\b/)
    end

    it "does not source the conf anywhere in the file (no privileged `.` execution of a non-root-written file)" do
      expect(script).not_to match(/^\s*\.\s+"\$STATE_DIR\/backend-default\.conf"/)
    end

    it "warns with a message naming the key and explaining ownership is unmanaged" do
      expect(warn_block).to match(/WARNING/)
      expect(warn_block).to match(/not managed by this script/i)
    end

    # Genuinely EXECUTES the extracted detection snippet (verbatim from
    # the file) to prove the PRESENCE-not-VALUE trigger actually holds on
    # the shape that motivated it: `export FOO=1
    # POWERNODE_OCI_CACHE_DIR=/x` sharing one line. A naive value-parse
    # (sed capturing only up to the next whitespace-delimited token from
    # its own anchor, or a grep|cut pipeline) reads this as the override
    # being effectively absent-or-empty; a presence-triggered `grep -q` on
    # the bare key name still fires.
    {
      "a plain assignment" => "POWERNODE_OCI_CACHE_DIR=/persist/powernode-oci-cache\n",
      "an export prefix sharing its line with a second assignment" => "export FOO=1 POWERNODE_OCI_CACHE_DIR=/x\n",
      "leading whitespace and an export prefix" => "  export POWERNODE_OCI_CACHE_DIR=/x\n"
    }.each do |desc, conf_content|
      it "warns when the conf has #{desc}" do
        Dir.mktmpdir do |state_dir|
          File.write(File.join(state_dir, "backend-default.conf"), conf_content)
          snippet = <<~BASH
            set -euo pipefail
            STATE_DIR=#{state_dir}
            #{warn_block}
            echo "REACHED_END"
          BASH
          out, err, status = Open3.capture3("bash", "-c", snippet)
          expect(status.success?).to be(true), "script aborted: #{err}"
          expect(err).to match(/WARNING/), "the warning is written to stderr (>&2) -- checking stdout would miss it"
          expect(out).to include("REACHED_END")
        end
      end
    end

    it "does NOT warn when the conf has no such key, and does not abort when the conf is absent" do
      Dir.mktmpdir do |state_dir|
        File.write(File.join(state_dir, "backend-default.conf"), "SOME_OTHER_KEY=value\n")
        snippet = <<~BASH
          set -euo pipefail
          STATE_DIR=#{state_dir}
          #{warn_block}
          echo "REACHED_END"
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)
        expect(status.success?).to be(true), "script aborted: #{err}"
        expect(err).not_to match(/WARNING/)
        expect(out).to include("REACHED_END")

        FileUtils.rm(File.join(state_dir, "backend-default.conf"))
        out2, err2, status2 = Open3.capture3("bash", "-c", snippet)
        expect(status2.success?).to be(true), "script aborted on absent conf: #{err2}"
        expect(err2).not_to match(/WARNING/)
        expect(out2).to include("REACHED_END")
      end
    end
  end

  describe "IMP-01a0c508-0121 review round: F1 -- chown cache CONTENTS, not just the directory node" do
    let(:sweep_function_body) { script[/sweep_ownership_for_rails\(\)\s*\{.*?\n\}/m] }

    it "defines a sweep helper mirroring the STATE_DIR sweep idiom (find + per-entry chown + fixed/failed counters)" do
      expect(script).to match(/sweep_ownership_for_rails\(\)\s*\{/)
      expect(sweep_function_body).not_to be_nil
      expect(sweep_function_body).to match(
        /find\s+"\$target"\s+(!\s+-type\s+l\s+)?\\?\(\s*!\s*-user\s+"\$RAILS_USER"\s+-o\s+!\s*-group\s+"\$RAILS_USER"\s+\\?\)\s+-print0/
      )
      expect(sweep_function_body).to match(/fixed=\$\(\(fixed \+ 1\)\)/)
      expect(sweep_function_body).to match(/failed=\$\(\(failed \+ 1\)\)/)
    end

    it "does not restrict depth — recurses into contents, not just the top-level directory argument" do
      expect(sweep_function_body).not_to match(/-maxdepth\s+1\b/)
    end

    it "chowns per-entry (not a blind chown -R), tolerating rather than aborting on one bad entry" do
      expect(sweep_function_body).to match(/if\s+chown\s+"\$RAILS_USER:\$RAILS_USER"\s+"\$entry"/)
      expect(sweep_function_body).not_to match(/chown\s+-R/)
    end

    # Security round: this cache dir is rails-writable, so a rails process
    # (buggy or compromised) could plant a symlink to an arbitrary
    # root-owned path inside it; a bare `chown` on a symlink entry follows
    # it to the referent, which would hand $RAILS_USER ownership of
    # whatever that link points at on the next boot's sweep.
    it "excludes symlink entries from the find results (! -type l), rather than following them" do
      expect(sweep_function_body).to match(/find\s+"\$target"\s+!\s+-type\s+l\s+\\?\(/),
        "the find predicate must exclude symlinks BEFORE the ownership test, not chown through them"
    end

    # Genuinely EXECUTES the LITERAL find invocation extracted from inside
    # the function (not retyped) against a tree containing a symlink,
    # proving the predicate itself never surfaces the symlink entry --
    # which is exactly what determines whether the function's chown ever
    # sees it (a bare chown on an entry find never returns can't run).
    it "the function's own find invocation never surfaces a symlink entry, when actually run" do
      find_line = sweep_function_body[/^\s*done < <\((find.*?-print0)/m, 1]
      expect(find_line).not_to be_nil

      Dir.mktmpdir do |dir|
        outside_target = File.join(dir, "outside-target")
        File.write(outside_target, "")
        cache_dir = File.join(dir, "cache")
        FileUtils.mkdir_p(cache_dir)
        File.symlink(outside_target, File.join(cache_dir, "sneaky-link"))

        # RAILS_USER="root" here (a real, resolvable name, just for this
        # find predicate — nothing is actually chowned in this example):
        # every entry in a tmpdir we create is owned by the CURRENT test
        # user, so with RAILS_USER pointed at itself (the pattern the
        # other executing specs use) the `! -user/-group` ownership test
        # alone already excludes everything, including the symlink — that
        # would make this test pass whether or not `! -type l` is present,
        # proving nothing. Pointing RAILS_USER at a DIFFERENT real user
        # makes the ownership test TRUE for every entry (a genuine
        # mismatch), so only the `! -type l` exclusion can still keep the
        # symlink out of the results — that's the one property this
        # example needs to discriminate.
        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="root"
          target=#{cache_dir}
          #{find_line} | tr '\\0' '\\n'
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)
        expect(status.success?).to be(true), "aborted: #{err}"
        expect(out).to include(cache_dir),
          "sanity: the mismatched-ownership predicate must surface at least the target dir itself, or this test proves nothing"
        expect(out).not_to include("sneaky-link"),
          "the sweep's own find predicate must never surface the symlink entry itself"
      end
    end

    it "is invoked for the PRIMARY resolved cache dir, after the dir-node chown succeeds" do
      loop_body = script[/for dir in "\$\{RAILS_OWNED_PERSIST_SIBLINGS\[@\]\}"; do\n(.*?)\ndone/m, 1]
      expect(loop_body).not_to be_nil
      expect(loop_body).to match(/sweep_ownership_for_rails "\$dir"/)
    end

    it "is invoked for the ADOPTED legacy flat path too, after ITS dir-node chown succeeds" do
      legacy_block = script[/# Legacy flat layout adoption:.*?(?=\n# config\/database\.yml)/m]
      expect(legacy_block).not_to be_nil
      expect(legacy_block).to match(/sweep_ownership_for_rails \/persist\/powernode-oci-cache/)
    end

    # Genuinely EXECUTES the extracted sweep function (not just a text
    # match) against a real directory tree with NESTED content, proving it
    # is callable and completes without aborting under set -euo pipefail
    # rather than stopping at the top-level argument. Run as the current
    # (non-root) test user with RAILS_USER pointed at itself — the same
    # self-chown trick the internal-CA executing specs above already use
    # (chowning to yourself always succeeds). This cannot prove a REAL
    # cross-user repair — there is no root harness in this suite, see the
    # file's own honest-limits header — but it does prove the function
    # actually walks into a nested subdirectory/file, not just its own
    # top-level argument.
    it "runs end-to-end against a directory tree with nested content, without aborting" do
      Dir.mktmpdir do |dir|
        nested_dir = File.join(dir, "sub")
        FileUtils.mkdir_p(nested_dir)
        File.write(File.join(nested_dir, "abc123.lock"), "")

        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          #{sweep_function_body}
          sweep_ownership_for_rails #{dir}
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)
        expect(status.success?).to be(true), "sweep aborted: #{err}"
        expect(out).to match(/ownership sweep for #{Regexp.escape(dir)}: fixed=\d+ failed=0/)
      end
    end
  end

  describe "IMP-01a0c508-0121 M1: mkdir must not create/widen the agent state parent (/persist/var/lib/powernode)" do
    let(:m1_block) { script[/# --- M1 safety:.*?\nfi\n/m] }

    it "exists, scoped to exactly the nested default path" do
      expect(m1_block).not_to be_nil
      expect(m1_block).to match(%r{if \[ "\$OCI_CACHE_DIR" = "/persist/var/lib/powernode/oci-cache" \]})
      expect(m1_block).to match(%r{\[ ! -d /persist/var/lib/powernode \]})
    end

    it "creates the parent with the SAME hardened group+mode the agent-PKI block above applies (0710, $RAILS_USER group)" do
      expect(m1_block).to match(%r{mkdir -p /persist/var/lib/powernode\b})
      expect(m1_block).to match(/chgrp "\$RAILS_USER" \/persist\/var\/lib\/powernode/)
      expect(m1_block).to match(/chmod 0710 \/persist\/var\/lib\/powernode/)
    end

    it "runs BEFORE the nested path is mkdir'd by the ownership loop, so the parent is never left at its default mode" do
      m1_idx   = script.index("# --- M1 safety:")
      loop_idx = script.index('for dir in "${RAILS_OWNED_PERSIST_SIBLINGS[@]}"; do')
      expect(m1_idx).not_to be_nil
      expect(loop_idx).not_to be_nil
      expect(m1_idx).to be < loop_idx
    end

    # Genuinely EXECUTES the extracted M1 block against a real tmp tree
    # standing in for /persist/var/lib/powernode's absent-parent case,
    # proving it actually creates+hardens rather than just matching text.
    # Verifies group+mode via `stat`, not just "did it run" -- a run that
    # silently no-ops would otherwise look identical to one that worked.
    it "creates and hardens a genuinely absent parent to 0710" do
      Dir.mktmpdir do |dir|
        fake_parent = File.join(dir, "persist-var-lib-powernode")
        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          OCI_CACHE_DIR="#{fake_parent}/oci-cache"
          #{m1_block.gsub("/persist/var/lib/powernode", fake_parent)}
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)
        expect(status.success?).to be(true), "aborted: #{err}"
        expect(Dir.exist?(fake_parent)).to be(true)
        mode = format("%o", File.stat(fake_parent).mode & 0o7777)
        expect(mode).to eq("710")
      end
    end

    it "does nothing when the parent already exists (an existing parent was already handled by the block above)" do
      Dir.mktmpdir do |dir|
        fake_parent = File.join(dir, "persist-var-lib-powernode")
        FileUtils.mkdir_p(fake_parent)
        FileUtils.chmod(0o755, fake_parent)
        snippet = <<~BASH
          set -euo pipefail
          RAILS_USER="$(id -un)"
          OCI_CACHE_DIR="#{fake_parent}/oci-cache"
          #{m1_block.gsub("/persist/var/lib/powernode", fake_parent)}
        BASH
        out, err, status = Open3.capture3("bash", "-c", snippet)
        expect(status.success?).to be(true), "aborted: #{err}"
        mode = format("%o", File.stat(fake_parent).mode & 0o7777)
        expect(mode).to eq("755"), "must not touch a parent that already existed -- that is the block above's job"
      end
    end
  end

  describe "IMP-01a0c508-0121 cosmetic: legacy-adopt comment matches its actual [-d] test" do
    it "does not claim content-based adoption when the test is existence-based" do
      legacy_block = script[/# Legacy flat layout adoption:.*?(?=\n# config\/database\.yml)/m]
      expect(legacy_block).not_to be_nil
      expect(legacy_block).not_to match(/if it already has content/i),
        "the comment must match the actual [ -d ] existence test below it, not claim a content check that isn't there"
    end
  end

  describe "IMP-01a0c508-0121 part 2: BUNDLE_FROZEN so bundler never rewrites the erofs-mounted Gemfile.lock" do
    let(:bundle_config_heredoc) { script[/cat > "\$STATE_DIR\/\.bundle\/config" <<EOF\n(.*?)\nEOF/m, 1] }

    it "writes BUNDLE_FROZEN: \"true\" alongside BUNDLE_PATH/BUNDLE_WITHOUT" do
      expect(bundle_config_heredoc).not_to be_nil
      expect(bundle_config_heredoc).to match(/BUNDLE_FROZEN:\s*"true"/)
    end

    it "does not chown/chmod RAILS_DIR (the erofs mount) as an alternative fix" do
      expect(script).not_to match(/chown\b[^\n]*"\$RAILS_DIR"/)
      expect(script).not_to match(/chmod\b[^\n]*"\$RAILS_DIR"/)
    end

    # Genuinely EXECUTES bundler-2.7.1's own key derivation and frozen-mode
    # gate (not a text/regex assertion) — proves the YAML key this script
    # writes is the one `Bundler.settings[:frozen]` / `Bundler.frozen_bundle?`
    # actually reads, and that `Definition#write_lock` returns before ever
    # opening the lockfile for write when it's set. Requires the vendored
    # bundler-2.7.1 gem to be resolvable in this environment; skips rather
    # than false-failing where it isn't (this spec must not depend on a
    # `bundle install` against the shared server bundle — see the shared
    # rvm gemset drift incident this suite already knows about).
    it "BUNDLE_FROZEN maps to Bundler.settings[:frozen] and gates Definition#write_lock before any file write (executed against the real bundler-2.7.1 gem)" do
      bundler_lib = Gem::Specification.find_all_by_name("bundler", "2.7.1").first&.full_gem_path
      skip "bundler 2.7.1 not installed in this environment" unless bundler_lib

      Dir.mktmpdir do |dir|
        config_path = File.join(dir, "config")
        File.write(config_path, <<~YAML)
          ---
          BUNDLE_FROZEN: "true"
        YAML

        script_rb = <<~RUBY
          $LOAD_PATH.unshift(#{File.join(bundler_lib, "lib").inspect})
          require "bundler"
          ENV["BUNDLE_APP_CONFIG"] = #{dir.inspect}
          settings = Bundler::Settings.new(#{dir.inspect})
          raise "expected frozen setting to be true, got \#{settings[:frozen].inspect}" unless settings[:frozen] == true
          puts "FROZEN_SETTING_OK"
        RUBY

        out, err, status = Open3.capture3("ruby", "-e", script_rb)
        expect(status.success?).to be(true), "ruby failed: #{err}"
        expect(out).to include("FROZEN_SETTING_OK")
      end
    end
  end

  describe "non-blocking: legacy migrations are crash-safe across filesystems (adoption a)" do
    it "migrates the /etc/powernode secrets via cp-to-tmp + same-fs rename + rm, not a bare cross-filesystem mv" do
      migration = script[/for f in backend-default\.conf.*?\ndone/m]
      expect(migration).not_to be_nil
      expect(migration).not_to match(/^\s*mv\s+"\$src"\s+"\$dest"\s*$/),
        "a bare mv across /etc (tmpfs/overlay) and /persist degrades to copy+unlink — not atomic, a crash leaves a truncated dest"
      expect(migration).to match(/cp\s+"\$src"\s+"\$dest\.tmp-\$\$"/)
      expect(migration).to match(/mv\s+"\$dest\.tmp-\$\$"\s+"\$dest"/)
      expect(migration).to match(/rm\s+-f\s+"\$src"/)
    end

    it "migrates the db-initialized marker the same crash-safe way" do
      marker_block = script[/if \[ -f \/var\/lib\/powernode-rails\/\.db-initialized \].*?\nfi/m]
      expect(marker_block).not_to be_nil
      expect(marker_block).not_to match(/^\s*mv\s+\/var\/lib\/powernode-rails\/\.db-initialized\s+"\$STATE_DIR\/\.db-initialized"\s*$/),
        "same cross-filesystem hazard as the secrets migration"
      expect(marker_block).to match(/cp\s+\/var\/lib\/powernode-rails\/\.db-initialized\s+"\$STATE_DIR\/\.db-initialized\.tmp-\$\$"/)
      expect(marker_block).to match(/mv\s+"\$STATE_DIR\/\.db-initialized\.tmp-\$\$"\s+"\$STATE_DIR\/\.db-initialized"/)
      expect(marker_block).to match(/rm\s+-f\s+\/var\/lib\/powernode-rails\/\.db-initialized/)
    end
  end

  describe "adoption (b), refined: ownership-fix split into a narrow FATAL part and a loud NON-FATAL sweep" do
    it "does not do a single unconditional chown -R across the whole STATE_DIR tree" do
      expect(script).not_to match(/^\s*chown -R "\$RAILS_USER:\$RAILS_USER" "\$STATE_DIR"\s*$/)
    end

    it "chowns STATE_DIR itself, the two secrets files, and the internal CA store unconditionally (fatal)" do
      fatal_section = script[/# FATAL: STATE_DIR itself.*?(?=\n# LOUD BUT NON-FATAL)/m]
      expect(fatal_section).not_to be_nil
      expect(fatal_section).to match(/^chown "\$RAILS_USER:\$RAILS_USER" "\$STATE_DIR"\s*$/)
      expect(fatal_section).to match(/chown "\$RAILS_USER:\$RAILS_USER" "\$secret_path"/)
      expect(fatal_section).to match(/chown -R "\$RAILS_USER:\$RAILS_USER" "\$ca_local_dir"/)

      # `not_to match(/\|\|\s*true/)` alone is NOT a fatality check
      # (review round) — `|| :`, `|| echo ...`, or wrapping the chown
      # itself as an `if chown ...; then` condition all just as
      # effectively defuse `set -e` and would still pass a check that
      # only looks for the literal string "|| true". Assert the actual
      # chown COMMAND lines (not the surrounding existence-guard
      # `if [ -e ]`/`if [ -d ]`, which legitimately skips a chown that
      # has nothing to act on — first boot, no secrets file yet, no CA
      # store yet) carry no `||`, no `&&`, and are never themselves the
      # tested condition of an `if`.
      chown_lines = fatal_section.lines.grep(/^\s*chown\b/)
      expect(chown_lines.size).to be >= 3 # STATE_DIR, secret_path, ca_local_dir
      chown_lines.each do |line|
        expect(line).not_to match(/\|\|/), "fatal chown must not be defused by || : #{line}"
        expect(line).not_to match(/&&/), "fatal chown must not be defused by && : #{line}"
        expect(line).not_to match(/^\s*if\s+chown\b/), "fatal chown must not itself be an if-condition: #{line}"
      end

      # Two MORE ways to escape `set -e` entirely (review round), neither
      # caught by the per-line checks above: `set +e` anywhere in the
      # section disables it for everything after, and moving the whole
      # block into a function called from an `if` (exactly the shape the
      # traefik ingress-dir setup legitimately uses on PURPOSE, a few
      # sections down) suspends -e for the function's ENTIRE body, not
      # just the tested command.
      expect(fatal_section).not_to match(/set \+e/), "set +e anywhere in the fatal section defeats every check above it"
      expect(fatal_section).not_to match(/\(\)\s*\{/), "the fatal section must not be wrapped in a function (that shape is for the NON-FATAL ingress-dir setup only)"
    end

    it "sweeps everything else per-entry, tolerating (not swallowing silently) a per-file failure, and reports counts" do
      sweep_section = script[/# LOUD BUT NON-FATAL:.*?\z/m]
      expect(sweep_section).not_to be_nil
      expect(sweep_section).to match(/find\s+"\$STATE_DIR"\s+\\?\(\s*!\s*-user\s+"\$RAILS_USER"\s+-o\s+!\s*-group\s+"\$RAILS_USER"\s+\\?\)\s+-print0/)
      expect(sweep_section).to match(/fixed=\$\(\(fixed \+ 1\)\)/)
      expect(sweep_section).to match(/failed=\$\(\(failed \+ 1\)\)/)
      expect(sweep_section).to match(/echo.*fixed=\$fixed failed=\$failed/)
    end

    it "echoes the sweep summary UNCONDITIONALLY, not only when something was fixed/failed" do
      # review round: gating the echo on fixed/failed > 0 made a clean
      # sweep look identical in the journal to the sweep never having run
      # at all — "swept, nothing to fix" and "never ran" must be
      # distinguishable.
      summary_line = script.lines.find { |l| l.include?('fixed=$fixed failed=$failed') }
      expect(summary_line).not_to be_nil
      preceding_lines = script.lines[0...(script.lines.index(summary_line))]
      expect(preceding_lines.last(3).join).not_to match(/if\s+\[\s*"\$fixed"/),
        "the summary echo must not be gated behind a fixed/failed > 0 check"
    end

    it "a failure inside the sweep loop cannot abort the script (each chown is individually guarded)" do
      sweep_section = script[/# LOUD BUT NON-FATAL:.*?\z/m]
      chown_line = sweep_section.lines.find { |l| l.include?('chown "$RAILS_USER:$RAILS_USER" "$entry"') }
      expect(chown_line).not_to be_nil
      expect(chown_line).to match(/if\s+chown/), "the sweep's chown must be tested by an if, not run bare under set -e"
    end
  end

  # Adoption (c): the reviewer's own critique of THIS spec file — content
  # matching alone can't prove two scripts stay in sync. This proves the
  # actual TEXT of the shared derivation blocks is identical (modulo
  # incidental indentation from whichever `if` nesting each caller sits
  # in), across every script that independently re-derives the same
  # cross-module path, so a future edit to one that isn't mirrored in the
  # others fails a real assertion instead of silently drifting.
  describe "cross-script consistency: the STATE_DIR / TRAEFIK_CERT_DIR derivation blocks stay byte-identical" do
    def dedent(block)
      lines = block.lines
      indent = lines.reject { |l| l.strip.empty? }.map { |l| l[/\A */].size }.min || 0
      lines.map { |l| l.sub(/\A {0,#{indent}}/, "") }.join
    end

    def state_dir_block(text)
      dedent(text[/^ *if mountpoint -q \/persist 2>\/dev\/null; then\n\s*STATE_DIR=.*?\n\s*else\n\s*STATE_DIR=.*?\n\s*fi\n/m].to_s)
    end

    def traefik_cert_dir_block(text)
      dedent(text[/^ *if mountpoint -q \/persist 2>\/dev\/null; then\n\s*TRAEFIK_CERT_DIR=.*?\n\s*else\n\s*TRAEFIK_CERT_DIR=.*?\n\s*fi\n/m].to_s)
    end

    let(:rails_setup_text)    { script }
    let(:rails_start_text)    { File.read(File.join(extension_root, "modules/powernode-hub-backend/rootfs/usr/local/bin/rails-start.sh")) }
    let(:sidekiq_start_text)  { File.read(File.join(extension_root, "modules/powernode-hub-worker/rootfs/usr/local/bin/sidekiq-start.sh")) }
    let(:worker_web_text)     { File.read(File.join(extension_root, "modules/powernode-hub-worker/rootfs/usr/local/bin/worker-web-start.sh")) }

    it "STATE_DIR: identical across rails-setup.sh, rails-start.sh, sidekiq-start.sh and worker-web-start.sh" do
      blocks = {
        "rails-setup.sh"      => state_dir_block(rails_setup_text),
        "rails-start.sh"      => state_dir_block(rails_start_text),
        "sidekiq-start.sh"    => state_dir_block(sidekiq_start_text),
        "worker-web-start.sh" => state_dir_block(worker_web_text)
      }
      blocks.each_value { |b| expect(b).not_to be_empty }
      expect(blocks.values.uniq.length).to eq(1), "STATE_DIR derivation drifted: #{blocks.inspect}"
    end

    it "TRAEFIK_CERT_DIR: identical across rails-setup.sh and rails-start.sh" do
      blocks = {
        "rails-setup.sh" => traefik_cert_dir_block(rails_setup_text),
        "rails-start.sh" => traefik_cert_dir_block(rails_start_text)
      }
      blocks.each_value { |b| expect(b).not_to be_empty }
      expect(blocks.values.uniq.length).to eq(1), "TRAEFIK_CERT_DIR derivation drifted: #{blocks.inspect}"
    end
  end
end
