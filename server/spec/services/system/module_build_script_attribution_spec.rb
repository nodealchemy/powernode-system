# frozen_string_literal: true

require "rails_helper"

# IMP-24d473c6f448 — System::ModuleBuildScriptAttribution derives, from the
# build scripts' own structure, which modules a scripts/module-build/* change
# belongs to. No slug is named in the service: every slug below comes from the
# fixture script's case arms.
RSpec.describe System::ModuleBuildScriptAttribution do
  let(:base_stage15) do
    <<~'SH'
      #!/usr/bin/env bash
      set -euo pipefail
      needs_parent=0
      case "$MODULE" in
        hub-backend|hub-worker) needs_parent=1 ;;
      esac

      # --- BEGIN needs-parent shared block ---
      if [ "$needs_parent" = "1" ]; then
        case "$parent_host" in
          github.com) clone_url="https://github.com/x/y.git" ;;
          *) clone_url="https://$parent_host/x/y.git" ;;
        esac
        git clone --depth 1 "$clone_url" /tmp/parent
        bash "$SCRIPT_DIR/parent-info.sh" > /tmp/parent-build-info.json
      fi
      # --- END needs-parent shared block ---

      case "$MODULE" in
        runtime-go)
          # a heredoc whose body holds a line that looks like a case terminator
          cat <<'EOF'
      esac
      EOF
          case "${ARCH:-amd64}" in
            amd64) GO_SHA=aaa ;;
            *) echo "FATAL: no pin"; exit 1 ;;
          esac
          ;;
        hub-backend)
          rsync -a /tmp/parent/server/ /tmp/fat/server/
          bash "$SCRIPT_DIR/assert-lock.sh" --workspace "$ws"
          ;;
        hub-worker|hub-frontend)
          bash "$SCRIPT_DIR/stage-files.sh" --workspace "$ws"
          ;;
        *)
          echo "no arm for $MODULE"
          ;;
      esac
      echo done
    SH
  end

  # The ONE definition of "packages parent-repo content" (needs-parent-modules.sh):
  # the shared block above is attributed to exactly these slugs, read from this
  # text, never from a list kept beside the reader.
  let(:needs_parent_sh) do
    <<~'SH'
      #!/usr/bin/env bash
      NEEDS_PARENT_MODULES="
      hub-backend
      hub-worker
      "
      module_needs_parent() { :; }
    SH
  end
  let(:needs_parent) { %w[hub-backend hub-worker] }

  # needs-parent-modules.sh as it was BEFORE the list existed (the shape every
  # ref older than IMP-c19b10a942d7 carries): present, a case statement, no
  # NEEDS_PARENT_MODULES. A range whose base is such a ref must still attribute.
  let(:pre_list_needs_parent_sh) do
    <<~'SH'
      #!/usr/bin/env bash
      # Is $1 a module whose build packages parent-repo content?
      module_needs_parent() {
        case "${1:-}" in
          hub-backend|hub-worker)
            return 0 ;;
          *)
            return 1 ;;
        esac
      }
    SH
  end
  # base_stage15 before the markers: the same code, nothing delimited.
  let(:pre_block_stage15) do
    base_stage15.gsub(/^# --- (BEGIN|END) needs-parent shared block ---\n/, "").tap { |t| raise "fixture edit missed" if t == base_stage15 }
  end

  def head_with(from, to)
    base_stage15.sub(from, to).tap { |t| raise "fixture edit missed: #{from}" if t == base_stage15 }
  end

  def attribute(head, changed: [ "scripts/module-build/stage15.sh" ], **opts)
    base = opts.fetch(:base) { base_stage15 }
    described_class.modules_for(
      changed_paths: changed, base_stage15: base, head_stage15: head,
      base_needs_parent: opts.fetch(:base_list) { needs_parent_sh },
      head_needs_parent: opts.fetch(:head_list) { needs_parent_sh }
    )
  end

  describe ".needs_parent_modules" do
    it "reads the slugs out of needs-parent-modules.sh's NEEDS_PARENT_MODULES list, in file order" do
      expect(described_class.needs_parent_modules(needs_parent_sh)).to eq(needs_parent)
    end

    it "is nil for no text (the file is absent at the ref)" do
      expect(described_class.needs_parent_modules(nil)).to be_nil
    end

    it "raises ParseError when the text carries no NEEDS_PARENT_MODULES list (renamed or removed)" do
      expect { described_class.needs_parent_modules("#!/bin/bash\nmodule_needs_parent() { :; }\n") }
        .to raise_error(described_class::ParseError, /NEEDS_PARENT_MODULES/)
    end

    it "raises ParseError on a token that is not a slug" do
      expect { described_class.needs_parent_modules("NEEDS_PARENT_MODULES=\"\nhub-backend\n$(x)\n\"\n") }
        .to raise_error(described_class::ParseError)
    end
  end

  describe ".parse" do
    subject(:parsed) { described_class.parse(base_stage15, needs_parent: needs_parent) }

    it "owns the shared block with the needs-parent slugs and nobody else" do
      expect(parsed.shared_block).to include("git clone --depth 1")
      expect(parsed.text_for("hub-backend")).to include("git clone --depth 1")
      expect(parsed.text_for("hub-worker")).to include("git clone --depth 1")
      expect(parsed.text_for("hub-frontend")).not_to include("git clone --depth 1")
      expect(parsed.text_for("runtime-go")).not_to include("git clone --depth 1")
    end

    it "captures the block verbatim, from BEGIN marker to END marker, nested case included" do
      expect(parsed.shared_block).to start_with("# --- BEGIN needs-parent shared block ---\n")
      expect(parsed.shared_block).to end_with("# --- END needs-parent shared block ---\n")
      expect(parsed.shared_block).to include("case \"$parent_host\" in")
    end

    it "counts a needs-parent slug with no arm of its own among the slugs" do
      expect(described_class.parse(base_stage15, needs_parent: %w[hub-backend vault]).slugs).to include("vault")
    end

    it "raises ParseError when needs-parent slugs are given but the script has no shared block (marker matched nothing)" do
      unmarked = base_stage15.gsub(/^# --- (BEGIN|END) needs-parent shared block ---\n/, "")
      expect(unmarked).not_to eq(base_stage15)
      expect { described_class.parse(unmarked, needs_parent: needs_parent) }
        .to raise_error(described_class::ParseError, /shared block/)
    end

    it "raises ParseError when the script has a shared block but no needs-parent slugs to own it" do
      expect { described_class.parse(base_stage15) }.to raise_error(described_class::ParseError, /shared block/)
      expect { described_class.parse(base_stage15, needs_parent: []) }.to raise_error(described_class::ParseError, /shared block/)
    end

    it "raises ParseError on a BEGIN marker with no END" do
      expect { described_class.parse(base_stage15.sub("# --- END needs-parent shared block ---\n", ""), needs_parent: needs_parent) }
        .to raise_error(described_class::ParseError, /shared block/)
    end

    it "raises ParseError on an END marker with no BEGIN" do
      expect { described_class.parse(base_stage15.sub("# --- BEGIN needs-parent shared block ---\n", ""), needs_parent: needs_parent) }
        .to raise_error(described_class::ParseError, /shared block/)
    end

    it "raises ParseError on a second shared block" do
      twice = base_stage15.sub("echo done\n", "# --- BEGIN needs-parent shared block ---\necho again\n# --- END needs-parent shared block ---\necho done\n")
      expect { described_class.parse(twice, needs_parent: needs_parent) }
        .to raise_error(described_class::ParseError, /shared block/)
    end

    it "raises ParseError on a BEGIN marker inside a module arm" do
      inside = head_with("    rsync -a /tmp/parent/server/", "    # --- BEGIN needs-parent shared block ---\n    rsync -a /tmp/parent/server/")
      expect { described_class.parse(inside, needs_parent: needs_parent) }
        .to raise_error(described_class::ParseError, /shared block/)
    end

    it "does not read a marker inside a heredoc body as a marker" do
      script = <<~'SH'
        case "$MODULE" in
          a)
            cat <<'EOF'
        # --- BEGIN needs-parent shared block ---
        EOF
            ;;
        esac
      SH
      expect(described_class.parse(script).arms.map(&:slugs)).to eq([ [ "a" ] ])
    end

    it "reads the literal slugs of every module-dispatch arm, across case blocks" do
      expect(parsed.arms.flat_map(&:slugs).uniq).to contain_exactly(
        "hub-backend", "hub-worker", "hub-frontend", "runtime-go"
      )
    end

    it "keeps a multi-slug arm as ONE arm owned by all of its slugs" do
      arm = parsed.arms.find { |a| a.slugs.include?("hub-frontend") }
      expect(arm.slugs).to contain_exactly("hub-worker", "hub-frontend")
    end

    it "marks a wildcard arm shared, with no slug" do
      wildcard = parsed.arms.find(&:wildcard?)
      expect(wildcard.slugs).to be_empty
    end

    it "does not mistake a nested case (a different variable) for module arms" do
      expect(parsed.arms.flat_map(&:slugs)).not_to include("amd64")
    end

    # F2: `esac ;;` on one line ends the nested case AND the arm. Before the fix the
    # arm stayed open and arm b was swallowed into arm a, so an edit to b was
    # attributed to a with no ParseError.
    it "closes an arm whose nested case ends with `esac ;;` on one line" do
      script = <<~'SH'
        case "$MODULE" in
          a)
            case "$ARCH" in
              amd64) x=1 ;;
            esac ;;
          b) echo b ;;
        esac
      SH
      expect(described_class.parse(script).arms.map(&:slugs)).to eq([ [ "a" ], [ "b" ] ])
    end

    it "closes an arm whose nested one-line case ends with `esac ;;`" do
      script = <<~'SH'
        case "$MODULE" in
          a)
            case "$ARCH" in amd64) x=1 ;;
            esac ;;
          b) echo b ;;
        esac
      SH
      expect(described_class.parse(script).arms.map(&:slugs)).to eq([ [ "a" ], [ "b" ] ])
    end

    # F4: a spaced heredoc opener is still a heredoc, so its body is not read as
    # structure; a spaced `<<` that is an append is still not.
    it "skips the body of a spaced `<< WORD` heredoc" do
      script = <<~'SH'
        case "$MODULE" in
          a)
            cat << EOF
          b) not an arm ;;
        EOF
            ;;
          c) echo c ;;
        esac
      SH
      arms = described_class.parse(script).arms
      expect(arms.map(&:slugs)).to eq([ [ "a" ], [ "c" ] ])
      expect(arms.first.text.lines.last.strip).to eq(";;") # the arm ran to ITS terminator, not the heredoc body's
    end

    it "skips the body of a spaced quoted `<< 'WORD'` heredoc" do
      script = <<~'SH'
        case "$MODULE" in
          a)
            cat << 'EOF'
          b) not an arm ;;
        EOF
            ;;
          c) echo c ;;
        esac
      SH
      arms = described_class.parse(script).arms
      expect(arms.map(&:slugs)).to eq([ [ "a" ], [ "c" ] ])
      expect(arms.first.text.lines.last.strip).to eq(";;") # the arm ran to ITS terminator, not the heredoc body's
    end

    it "does not read a spaced append (`list << item.name`) as a heredoc" do
      script = <<~'SH'
        case "$MODULE" in
          a)
            ruby -e 'missing << spec.full_name'
            ;;
          c) echo c ;;
        esac
      SH
      expect(described_class.parse(script).arms.map(&:slugs)).to eq([ [ "a" ], [ "c" ] ])
    end

    it "raises ParseError on an unbalanced case/esac" do
      expect { described_class.parse(base_stage15.sub(/^esac\necho done/, "echo done"), needs_parent: needs_parent) }
        .to raise_error(described_class::ParseError)
    end

    it "raises ParseError when the script has no module dispatch at all" do
      expect { described_class.parse("#!/bin/bash\necho hi\n") }.to raise_error(described_class::ParseError)
    end
  end

  describe ".modules_for" do
    it "attributes a change inside one module's arm to that module only" do
      head = head_with("rsync -a /tmp/parent/server/", "rsync -aH /tmp/parent/server/")
      expect(attribute(head)).to contain_exactly("hub-backend")
    end

    it "attributes a change inside a multi-slug arm to every slug of the arm" do
      head = head_with("--workspace \"$ws\"\n    ;;\n  *)", "--workspace \"$ws\" --fast\n    ;;\n  *)")
      expect(attribute(head)).to contain_exactly("hub-worker", "hub-frontend")
    end

    it "attributes a change inside a nested case to the enclosing module arm" do
      head = head_with("amd64) GO_SHA=aaa ;;", "amd64) GO_SHA=bbb ;;")
      expect(attribute(head)).to contain_exactly("runtime-go")
    end

    it "attributes a change to the needs_parent dispatch to the slugs it names" do
      head = head_with("hub-backend|hub-worker) needs_parent=1 ;;", "hub-backend|hub-worker) needs_parent=2 ;;")
      expect(attribute(head)).to contain_exactly("hub-backend", "hub-worker")
    end

    # IMP-c19b10a942d7: the parent clone + BUILD_INFO.json block sits outside every
    # arm but feeds exactly the needs-parent modules. It belongs to the slugs
    # needs-parent-modules.sh lists — hub-frontend has an arm but is NOT listed
    # here, so it must not move.
    it "attributes a change inside the needs-parent shared block to the listed modules, and only them" do
      head = head_with("git clone --depth 1 \"$clone_url\" /tmp/parent", "git clone --depth 1 --no-tags \"$clone_url\" /tmp/parent")
      expect(attribute(head)).to contain_exactly("hub-backend", "hub-worker")
    end

    it "attributes a change inside the block's nested case to the listed modules" do
      head = head_with("github.com) clone_url=", "github.com|*.github.com) clone_url=")
      expect(attribute(head)).to contain_exactly("hub-backend", "hub-worker")
    end

    it "attributes a slug ADDED to the needs-parent list to that slug (the block is newly its input)" do
      grown = needs_parent_sh.sub("hub-worker\n", "hub-worker\nhub-frontend\n")
      expect(attribute(base_stage15, changed: [ "scripts/module-build/needs-parent-modules.sh" ], head_list: grown))
        .to contain_exactly("hub-frontend")
    end

    it "attributes a change to a helper the block calls to the listed modules" do
      expect(attribute(base_stage15, changed: [ "scripts/module-build/parent-info.sh" ]))
        .to contain_exactly("hub-backend", "hub-worker")
    end

    # A range whose BASE predates the list: needs-parent-modules.sh is present
    # there in its old case-statement shape, and stage15.sh has no block. That
    # pair is the pre-list era and reads as "no list" on the base side only, so
    # the range still attributes; the head side keeps refusing a list-less file.
    describe "a range whose base predates the list" do
      def attribute_from_pre_list(head, changed: [ "scripts/module-build/stage15.sh", "scripts/module-build/needs-parent-modules.sh" ])
        attribute(head, changed: changed, base: pre_block_stage15, base_list: pre_list_needs_parent_sh)
      end

      it "attributes the block's arrival to the listed modules" do
        expect(attribute_from_pre_list(base_stage15)).to contain_exactly("hub-backend", "hub-worker")
      end

      it "still attributes an ordinary arm edit in that range" do
        head = head_with("amd64) GO_SHA=aaa ;;", "amd64) GO_SHA=bbb ;;")
        expect(attribute_from_pre_list(head)).to contain_exactly("hub-backend", "hub-worker", "runtime-go")
      end

      it "attributes an arm edit alone when the head has no block either (no list on either side)" do
        head = pre_block_stage15.sub("amd64) GO_SHA=aaa ;;", "amd64) GO_SHA=bbb ;;")
        expect(attribute(head, base: pre_block_stage15, base_list: pre_list_needs_parent_sh, head_list: nil))
          .to contain_exactly("runtime-go")
      end

      it "raises ParseError when the pre-list-shaped base file sits beside a base stage15.sh that HAS a block" do
        expect { attribute(base_stage15, base: base_stage15, base_list: pre_list_needs_parent_sh) }
          .to raise_error(described_class::ParseError, /shared block/)
      end

      it "raises ParseError on the HEAD side for a file without the list, whatever the script" do
        expect { attribute(pre_block_stage15, base: pre_block_stage15, base_list: nil, head_list: pre_list_needs_parent_sh) }
          .to raise_error(described_class::ParseError, /NEEDS_PARENT_MODULES/)
      end
    end

    it "raises ParseError when needs-parent-modules.sh changed but no base copy of stage15.sh is available" do
      expect { attribute(base_stage15, changed: [ "scripts/module-build/needs-parent-modules.sh" ], base: nil) }
        .to raise_error(described_class::ParseError, /base/)
    end

    it "attributes an ADDED arm to its slug" do
      head = head_with("  *)\n    echo \"no arm", "  redis)\n    echo hi\n    ;;\n  *)\n    echo \"no arm")
      expect(attribute(head)).to contain_exactly("redis")
    end

    it "attributes NOTHING for a change outside every arm (shared code)" do
      head = head_with("echo done", "echo finished")
      expect(attribute(head)).to be_empty
    end

    it "attributes NOTHING for a change inside the wildcard arm (shared code)" do
      head = head_with("echo \"no arm for $MODULE\"", "echo \"unknown module $MODULE\"")
      expect(attribute(head)).to be_empty
    end

    it "attributes an unchanged stage15.sh to nothing" do
      expect(attribute(base_stage15)).to be_empty
    end

    context "a changed helper script" do
      it "attributes it to every arm that calls it" do
        expect(attribute(base_stage15, changed: [ "scripts/module-build/assert-lock.sh" ]))
          .to contain_exactly("hub-backend")
        expect(attribute(base_stage15, changed: [ "scripts/module-build/stage-files.sh" ]))
          .to contain_exactly("hub-worker", "hub-frontend")
      end

      it "attributes a helper no arm calls to nothing" do
        expect(attribute(base_stage15, changed: [ "scripts/module-build/should-skip-build.sh" ])).to be_empty
      end

      it "does not treat a name that merely CONTAINS a helper's name as a call" do
        head = head_with("assert-lock.sh", "assert-lock.sh.bak.sh")
        expect(attribute(head, changed: [ "scripts/module-build/lock.sh" ], base: head)).to be_empty
      end

      it "ignores a helper mentioned only in a comment" do
        head = head_with("rsync -a /tmp/parent/server/", "# see also unrelated-helper.sh\n    rsync -a /tmp/parent/server/")
        expect(attribute(head, changed: [ "scripts/module-build/unrelated-helper.sh" ], base: head)).to be_empty
      end

      it "unions a stage15.sh arm change with a helper change" do
        head = head_with("amd64) GO_SHA=aaa ;;", "amd64) GO_SHA=bbb ;;")
        changed = [ "scripts/module-build/stage15.sh", "scripts/module-build/assert-lock.sh" ]
        expect(attribute(head, changed: changed)).to contain_exactly("runtime-go", "hub-backend")
      end
    end

    it "raises ParseError when stage15.sh changed but no base copy is available" do
      expect { attribute(base_stage15, base: nil) }.to raise_error(described_class::ParseError, /base/)
    end

    it "needs no base copy when only a helper changed" do
      expect(attribute(base_stage15, changed: [ "scripts/module-build/assert-lock.sh" ], base: nil))
        .to contain_exactly("hub-backend")
    end
  end

  # The fixture proves the parser on a shape the author chose; this proves it on
  # the shape the file actually has, so a stage15.sh rewrite that the parser
  # cannot read fails HERE, in CI, rather than silently degrading production
  # planning to its module-forge-only fallback.
  describe "against the real stage15.sh" do
    let(:scripts_dir) { File.expand_path("../../../../scripts/module-build", __dir__) }
    let(:real) { File.read("#{scripts_dir}/stage15.sh") }
    let(:real_list) { File.read("#{scripts_dir}/needs-parent-modules.sh") }
    let(:real_needs_parent) { described_class.needs_parent_modules(real_list) }

    def attribute_real(head, changed: [ "scripts/module-build/stage15.sh" ])
      attribute(head, changed: changed, base: real, base_list: real_list, head_list: real_list)
    end

    it "parses without raising and finds arms for the platform modules" do
      parsed = described_class.parse(real, needs_parent: real_needs_parent)
      slugs = parsed.arms.flat_map(&:slugs)
      expect(slugs).to include("powernode-hub-backend", "powernode-hub-worker", "powernode-extension-system", "module-forge")
    end

    it "reads the needs-parent list out of the real needs-parent-modules.sh" do
      expect(real_needs_parent).to contain_exactly(
        "powernode-hub-backend", "powernode-hub-worker", "powernode-hub-frontend", "powernode-extension-system"
      )
    end

    it "attributes an edit inside the hub-backend arm to hub-backend alone" do
      edited = real.sub("--exclude='log' --exclude='coverage' --exclude='extensions' \\\n", "--exclude='log' --exclude='coverage' --exclude='extensions' --exclude='vendor' \\\n")
      expect(edited).not_to eq(real)
      expect(attribute_real(edited)).to contain_exactly("powernode-hub-backend")
    end

    it "attributes a change to a helper called from the hub-backend arm to that arm's module" do
      expect(attribute_real(real, changed: [ "scripts/module-build/assert-gemfile-lock-has-extension-path.sh" ]))
        .to contain_exactly("powernode-hub-backend")
    end

    # IMP-c19b10a942d7: the parent clone / BUILD_INFO.json block is shared code
    # outside every arm, but it is an input of exactly the needs-parent modules.
    it "attributes an edit inside the needs-parent shared block to the four needs-parent modules and no other" do
      edited = real.sub("echo \"[stage-1.5] build identity: ", "echo \"[stage-1.5] build identity (edited): ")
      expect(edited).not_to eq(real)
      expect(attribute_real(edited)).to match_array(real_needs_parent)
    end

    # Pins the HEAD of the real block, not just its tail: a BEGIN marker that
    # drifted below the needs_parent guard or below the clone would still parse,
    # and the text it left outside would attribute to nobody.
    it "delimits the real block from the needs_parent guard through the parent clone" do
      block = described_class.parse(real, needs_parent: real_needs_parent).shared_block
      expect(block).to start_with("# --- BEGIN needs-parent shared block ---\nif [ \"$needs_parent\" = \"1\" ]; then\n")
      expect(block).to include("git clone --depth 1 \"$clone_url\" /tmp/parent\n")
      expect(block).to include("> /tmp/parent-build-info.json\n")
      expect(block).to end_with("fi\n# --- END needs-parent shared block ---\n")
    end

    it "attributes an edit outside the block and every arm to nothing" do
      edited = real.sub("rm -f /tmp/parent-provenance.env\n", "rm -f /tmp/parent-provenance.env # edited\n")
      expect(edited).not_to eq(real)
      expect(attribute_real(edited)).to be_empty
    end
  end
end
