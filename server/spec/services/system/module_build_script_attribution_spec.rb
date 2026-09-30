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

  def head_with(from, to)
    base_stage15.sub(from, to).tap { |t| raise "fixture edit missed: #{from}" if t == base_stage15 }
  end

  def attribute(head, changed: [ "scripts/module-build/stage15.sh" ], **opts)
    base = opts.fetch(:base) { base_stage15 }
    described_class.modules_for(changed_paths: changed, base_stage15: base, head_stage15: head)
  end

  describe ".parse" do
    subject(:parsed) { described_class.parse(base_stage15) }

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
      expect { described_class.parse(base_stage15.sub(/^esac\necho done/, "echo done")) }
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
    let(:real) { File.read(File.expand_path("../../../../scripts/module-build/stage15.sh", __dir__)) }

    it "parses without raising and finds arms for the platform modules" do
      parsed = described_class.parse(real)
      slugs = parsed.arms.flat_map(&:slugs)
      expect(slugs).to include("powernode-hub-backend", "powernode-hub-worker", "powernode-extension-system", "module-forge")
    end

    it "attributes an edit inside the hub-backend arm to hub-backend alone" do
      edited = real.sub("--exclude='log' --exclude='coverage' --exclude='extensions' \\\n", "--exclude='log' --exclude='coverage' --exclude='extensions' --exclude='vendor' \\\n")
      expect(edited).not_to eq(real)
      expect(attribute(edited, base: real)).to contain_exactly("powernode-hub-backend")
    end

    it "attributes a change to a helper called from the hub-backend arm to that arm's module" do
      expect(attribute(real, changed: [ "scripts/module-build/assert-gemfile-lock-has-extension-path.sh" ], base: real))
        .to contain_exactly("powernode-hub-backend")
    end
  end
end
