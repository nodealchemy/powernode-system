# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "fileutils"

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
