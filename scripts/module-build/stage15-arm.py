#!/usr/bin/env python3
"""stage15-arm.py -- read ONE module's arm out of stage15.sh's module dispatch.

Used by compute-build-inputs-hash.sh (IMP-24d473c6f448) so the content-addressed
build skip hashes exactly the build inputs stage15.sh gives a module: that
module's own `case "$MODULE" in <slug>) ... ;;` arm, and the scripts/module-build
helpers the arm calls -- not the whole scripts tree, and not another module's arm.

Plus the shared parent-clone block (IMP-c19b10a942d7): the text between
stage15.sh's `# --- BEGIN needs-parent shared block ---` and
`# --- END needs-parent shared block ---` markers sits outside every arm but is
an input of exactly the modules needs-parent-modules.sh lists. Given that file
(--needs-parent-modules), the block is folded into those modules' text and no
other. A marker that matches nothing is an error, never a silent omission: a
non-empty list with no block, a block with no list, BEGIN without END, END
without BEGIN, a second block, or a marker inside a case all exit 2.

THIS IS A LINE-FOR-LINE PORT of the reader in
server/app/services/system/module_build_script_attribution.rb (the build planner's
attribution). The two must agree on which arms exist and what text each holds, or
the planner would target a module whose skip hash never moved (or the reverse).
server/spec/services/system/module_build_script_attribution_parity_spec.rb runs
both over the real stage15.sh and asserts they agree; change one, change both.

Usage:
  stage15-arm.py [--needs-parent-modules FILE] MODULE [HELPER ...] < stage15.sh
      exit 0: prints `arm-sha256 <hex>` over MODULE's attributed text (its arms,
              plus the shared block when MODULE is listed) and one
              `helper <name>` line per HELPER (a basename) that a non-comment
              line of that text calls, sorted.
      exit 1: MODULE has no arm of its own and is not listed (nothing printed).
      exit 2: the script could not be read faithfully (stderr says why).
  stage15-arm.py [--needs-parent-modules FILE] --dump MODULE < stage15.sh
      the attributed text itself (exit codes as above)
  stage15-arm.py [--needs-parent-modules FILE] --slugs < stage15.sh
      every literal slug that has an arm or is listed, sorted
  stage15-arm.py --needs-parent-modules FILE --needs-parent-list
      the slugs read out of FILE, in file order (exit 2 if it has no list)

FILE is needs-parent-modules.sh at the same ref as the script on stdin. Without
it the script must have no shared block.

The script is read and re-emitted as latin-1 so bytes are never altered.
"""
import hashlib
import re
import sys

A = re.ASCII

MODULE_SCRUTINEE_RX = re.compile(r'"?\$\{?MODULE\}?"?', A)
CASE_OPEN_RX = re.compile(r'\s*case\s+(.+?)\s+in\b(.*)', A)
ESAC_RX = re.compile(r'\s*esac\b', A)
ARM_START_RX = re.compile(
    r'''\s*\(?\s*((?:"[^"]*"|'[^']*'|[^\s)|"'])+(?:\s*\|\s*(?:"[^"]*"|'[^']*'|[^\s)|"'])+)*)\s*\)(.*)''', A)
ARM_END_RX = re.compile(r';;&?\s*(?:#.*)?\Z|;&\s*(?:#.*)?\Z', A)
HEREDOC_RX = re.compile(r'''(?<!<)<<-?(["']?)([A-Za-z_]\w*)\1''', A)
HEREDOC_SPACED_RX = re.compile(
    r'''(?<!<)<<-?\s+(?:(["'])([A-Za-z_]\w*)\1|([A-Z][A-Z0-9_]*)(?=\s|;|\)|\Z))''', A)
COMMENT_RX = re.compile(r'\s*#', A)
LITERAL_SLUG_RX = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*', A)
ESAC_WORD_RX = re.compile(r'\besac\b', A)
# The shared block's two markers, each on a line of its own.
SHARED_BLOCK_RX = re.compile(r'\s*#\s*---\s*(BEGIN|END) needs-parent shared block\s*---\s*', A)
# needs-parent-modules.sh's list: the ONE definition of which modules own the block.
NEEDS_PARENT_LIST_RX = re.compile(r'^NEEDS_PARENT_MODULES="([^"]*)"', re.M | A)
WS = " \t\r\n\f\v"


class ParseError(Exception):
    pass


def each_line(text):
    pos = 0
    while pos < len(text):
        i = text.find("\n", pos)
        end = len(text) if i < 0 else i + 1
        yield text[pos:end]
        pos = end


def chomp(raw):
    if raw.endswith("\r\n"):
        return raw[:-2]
    if raw.endswith("\n") or raw.endswith("\r"):
        return raw[:-1]
    return raw


def finish(cur):
    literal = [p for p in cur["patterns"] if LITERAL_SLUG_RX.fullmatch(p)]
    return {"slugs": literal, "text": "".join(cur["text"])}


def needs_parent_modules(text):
    """The slugs needs-parent-modules.sh lists, in file order; None for no text."""
    if text is None:
        return None
    lists = NEEDS_PARENT_LIST_RX.findall(text)
    if not lists:
        raise ParseError('needs-parent-modules.sh has no NEEDS_PARENT_MODULES="..." list')
    # Both readers take the first definition; bash sourcing takes the last. Two
    # definitions could fold the block into one set of modules while
    # module_needs_parent() answers for another, so the file is refused.
    if len(lists) > 1:
        raise ParseError("needs-parent-modules.sh defines NEEDS_PARENT_MODULES more than once")
    # Split exactly as bash's default IFS word-splits the list -- space, tab,
    # newline -- so any other separator stays glued to a slug and is refused
    # (str.split() would also split on \r, \v, \f, \x1c-\x1f, \x85 and \xa0).
    slugs = [s for s in re.split("[ \t\n]+", lists[0]) if s]
    for s in slugs:
        if not LITERAL_SLUG_RX.fullmatch(s):
            raise ParseError("needs-parent list entry %r is not a module slug" % s)
    return slugs


def parse(script, needs_parent=None):
    needs_parent = list(needs_parent or [])
    arms = []
    stack = []
    current = None
    heredoc = None
    block = None        # the shared block's lines while it is open
    shared = None       # its text once closed

    for raw in each_line(script):
        line = chomp(raw)

        if heredoc is not None:
            if current is not None:
                current["text"].append(raw)
            if block is not None:
                block.append(raw)
            if line.strip(WS) == heredoc:
                heredoc = None
            continue

        bm = SHARED_BLOCK_RX.fullmatch(line)
        if bm:
            if bm.group(1) == "BEGIN":
                if block is not None or shared is not None:
                    raise ParseError("second needs-parent shared block BEGIN")
                if stack or current is not None:
                    raise ParseError("needs-parent shared block BEGIN inside a case")
                block = [raw]
            else:
                if block is None:
                    raise ParseError("needs-parent shared block END with no BEGIN")
                if stack:
                    raise ParseError("needs-parent shared block END inside a case")
                block.append(raw)
                shared = "".join(block)
                block = None
            continue
        if block is not None:
            block.append(raw)

        if COMMENT_RX.match(line):
            if current is not None:
                current["text"].append(raw)
            continue

        m = CASE_OPEN_RX.fullmatch(line)
        if m:
            if not ESAC_WORD_RX.search(m.group(2)):
                module_dispatch = not stack and MODULE_SCRUTINEE_RX.fullmatch(m.group(1)) is not None
                # A dispatch inside the block would put its arms in the arm's slug
                # AND every listed module; the block's own non-MODULE cases are fine.
                if module_dispatch and block is not None:
                    raise ParseError('a `case "$MODULE" in` dispatch opens inside the needs-parent shared block')
                stack.append(module_dispatch)
            if current is not None:
                current["text"].append(raw)
        elif ESAC_RX.match(line):
            if not stack:
                raise ParseError("esac with no open case")
            was_dispatch = stack.pop()
            if was_dispatch and current is not None:
                arms.append(finish(current))
                current = None
            elif current is not None:
                current["text"].append(raw)
                if len(stack) == 1 and stack[0] and ARM_END_RX.search(line):
                    arms.append(finish(current))
                    current = None
        elif len(stack) == 1 and stack[0]:
            if current is None:
                am = ARM_START_RX.fullmatch(line)
                if am:
                    pats = [p.strip(WS).replace('"', "").replace("'", "") for p in am.group(1).split("|")]
                    current = {"patterns": pats, "text": [raw]}
                    if ARM_END_RX.search(am.group(2)):
                        arms.append(finish(current))
                        current = None
            else:
                current["text"].append(raw)
                if ARM_END_RX.search(line):
                    arms.append(finish(current))
                    current = None
        elif current is not None:
            current["text"].append(raw)

        hm = HEREDOC_RX.search(line)
        if hm:
            heredoc = hm.group(2)
        else:
            sm = HEREDOC_SPACED_RX.search(line)
            if sm:
                heredoc = sm.group(2) or sm.group(3)

    if stack:
        raise ParseError("unterminated case (%d open at end of script)" % len(stack))
    if block is not None:
        raise ParseError("unterminated needs-parent shared block (BEGIN with no END)")
    if not arms:
        raise ParseError('no `case "$MODULE" in` dispatch found')
    if needs_parent and shared is None:
        raise ParseError("needs-parent modules are listed but the script has no needs-parent shared block")
    if shared is not None and not needs_parent:
        raise ParseError("the script has a needs-parent shared block but no needs-parent module list owns it")
    return {"arms": arms, "shared": shared, "needs_parent": needs_parent}


def slugs_of(parsed):
    return {s for a in parsed["arms"] for s in a["slugs"]} | set(parsed["needs_parent"])


def text_for(parsed, slug):
    text = "".join(a["text"] for a in parsed["arms"] if slug in a["slugs"])
    if parsed["shared"] is not None and slug in parsed["needs_parent"]:
        text += parsed["shared"]
    return text


def calls(arm_text, helper):
    rx = re.compile(r'(?<![\w.-])' + re.escape(helper) + r'(?![\w.-])', A)
    return any(not COMMENT_RX.match(chomp(l)) and rx.search(l) for l in each_line(arm_text))


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2

    needs_parent_text = None
    if argv[0] == "--needs-parent-modules":
        if len(argv) < 2:
            sys.stderr.write("stage15-arm.py: --needs-parent-modules requires a FILE\n")
            return 2
        try:
            with open(argv[1], "rb") as f:
                needs_parent_text = f.read().decode("latin-1")
        except OSError as e:
            sys.stderr.write("stage15-arm.py: cannot read %s: %s\n" % (argv[1], e))
            return 2
        argv = argv[2:]
        if not argv:
            sys.stderr.write("stage15-arm.py: MODULE, --slugs, --dump or --needs-parent-list required\n")
            return 2

    try:
        needs_parent = needs_parent_modules(needs_parent_text)
        if argv[0] == "--needs-parent-list":
            if needs_parent is None:
                raise ParseError("--needs-parent-list needs --needs-parent-modules FILE")
            for s in needs_parent:
                print(s)
            return 0
        script = sys.stdin.buffer.read().decode("latin-1")
        parsed = parse(script, needs_parent)
    except ParseError as e:
        sys.stderr.write("stage15-arm.py: %s\n" % e)
        return 2

    if argv[0] == "--slugs":
        print("\n".join(sorted(slugs_of(parsed))))
        return 0

    dump = argv[0] == "--dump"
    args = argv[1:] if dump else argv
    if not args:
        sys.stderr.write("stage15-arm.py: MODULE required\n")
        return 2
    module, helpers = args[0], args[1:]

    if module not in slugs_of(parsed):
        return 1
    text = text_for(parsed, module)
    if dump:
        sys.stdout.buffer.write(text.encode("latin-1"))
        return 0
    print("arm-sha256 " + hashlib.sha256(text.encode("latin-1")).hexdigest())
    for h in sorted(set(helpers)):
        if calls(text, h):
            print("helper " + h)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
