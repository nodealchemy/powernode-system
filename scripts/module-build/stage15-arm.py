#!/usr/bin/env python3
"""stage15-arm.py -- read ONE module's arm out of stage15.sh's module dispatch.

Used by compute-build-inputs-hash.sh (IMP-24d473c6f448) so the content-addressed
build skip hashes exactly the build inputs stage15.sh gives a module: that
module's own `case "$MODULE" in <slug>) ... ;;` arm, and the scripts/module-build
helpers the arm calls -- not the whole scripts tree, and not another module's arm.

THIS IS A LINE-FOR-LINE PORT of the reader in
server/app/services/system/module_build_script_attribution.rb (the build planner's
attribution). The two must agree on which arms exist and what text each holds, or
the planner would target a module whose skip hash never moved (or the reverse).
server/spec/services/system/module_build_script_attribution_parity_spec.rb runs
both over the real stage15.sh and asserts they agree; change one, change both.

Usage:
  stage15-arm.py MODULE [HELPER ...] < stage15.sh
      exit 0: prints `arm-sha256 <hex>` and one `helper <name>` line per HELPER
              (a basename) that a non-comment line of the arm calls, sorted.
      exit 1: MODULE has no arm of its own (nothing printed).
      exit 2: the script could not be read faithfully (stderr says why).
  stage15-arm.py --dump MODULE < stage15.sh   the arm text itself (exit codes as above)
  stage15-arm.py --slugs < stage15.sh         every literal slug that has an arm, sorted

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


def parse(script):
    arms = []
    stack = []
    current = None
    heredoc = None

    for raw in each_line(script):
        line = chomp(raw)

        if heredoc is not None:
            if current is not None:
                current["text"].append(raw)
            if line.strip(WS) == heredoc:
                heredoc = None
            continue

        if COMMENT_RX.match(line):
            if current is not None:
                current["text"].append(raw)
            continue

        m = CASE_OPEN_RX.fullmatch(line)
        if m:
            if not ESAC_WORD_RX.search(m.group(2)):
                stack.append(not stack and MODULE_SCRUTINEE_RX.fullmatch(m.group(1)) is not None)
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
    if not arms:
        raise ParseError('no `case "$MODULE" in` dispatch found')
    return arms


def text_for(arms, slug):
    return "".join(a["text"] for a in arms if slug in a["slugs"])


def calls(arm_text, helper):
    rx = re.compile(r'(?<![\w.-])' + re.escape(helper) + r'(?![\w.-])', A)
    return any(not COMMENT_RX.match(chomp(l)) and rx.search(l) for l in each_line(arm_text))


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    script = sys.stdin.buffer.read().decode("latin-1")
    try:
        arms = parse(script)
    except ParseError as e:
        sys.stderr.write("stage15-arm.py: %s\n" % e)
        return 2

    if argv[0] == "--slugs":
        print("\n".join(sorted({s for a in arms for s in a["slugs"]})))
        return 0

    dump = argv[0] == "--dump"
    args = argv[1:] if dump else argv
    if not args:
        sys.stderr.write("stage15-arm.py: MODULE required\n")
        return 2
    module, helpers = args[0], args[1:]

    if not any(module in a["slugs"] for a in arms):
        return 1
    text = text_for(arms, module)
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
