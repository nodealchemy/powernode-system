# Mermaid Render Parity — Gitea + GitHub

The extension's doc corpus contains 62 Mermaid diagrams as of 2026-06-07
(52 at the 2026-05-17 parity pass; the full set was re-validated on
2026-06-07 — see "Offline batch validation" below). Both Gitea (≥ v1.17)
and the GitHub mirror render Mermaid natively, but not always identically.
This document captures which Mermaid features are verified to render the
same on both targets, plus the procedure for testing new diagram types.

## Verified-parity feature matrix

The following Mermaid syntax is in use across the corpus and verified
to render identically on both Gitea and GitHub mirror as of the
modernization pass:

| Mermaid feature | Verified on | Diagrams using it |
|-----------------|-------------|-------------------|
| `flowchart TB/TD/LR` with subgraphs | both | ARCHITECTURE.md (three-tier), tutorials/INDEX.md (decision tree), federation/SPAWN_MODES.md, etc. |
| `sequenceDiagram` with `actor`, `participant`, alt/else/loop blocks | both | CONTAINER_RUNTIMES.md, agent-internals.md (5 diagrams), tutorial 03, federation/NETWORK_TRUST.md |
| `stateDiagram-v2` with notes + composite states | both | ARCHITECTURE.md (NodeInstance AASM, module promotion), agent-peering.md, federation/NETWORK_TRUST.md |
| Dotted lines (`-.->`) for non-blocking calls | both | ARCHITECTURE.md (trust boundaries), CONTAINER_RUNTIMES.md (Multi-cluster) |
| HTML `<br/>` line breaks inside node labels | both | All diagrams use this convention |
| Quoted node labels with special characters | both | tutorials/01-first-boot.md (paths with `/`), agent-internals.md |
| Sequence `Note over X,Y` annotations | both | tutorial 04 (VIP failover), tutorial 11 (federation) |
| Conditional rendering (`alt`/`else`/`end`) | both | acme-issuance.md (issuance flow), credential-restoration.md (DR sequence) |

## Diagram class conventions

When choosing a diagram type for new content, follow these
already-validated patterns:

| Use case | Recommended type | Example |
|----------|------------------|---------|
| Agent/protocol interaction with multiple parties | `sequenceDiagram` | Docker handshake, K3s bootstrap, ACME issuance |
| Component topology / data flow | `flowchart LR` or `flowchart TB` | Three-tier model, stigmergic exchange, runtime registry |
| Lifecycle / state machine | `stateDiagram-v2` | NodeInstance AASM, module promotion, federation bridge |
| Decision tree / branching | `flowchart TD` with diamond `{}` | tutorials/INDEX.md, GitOps apply branch, CVE response |

## Procedure for testing a new diagram

When introducing a Mermaid feature not in the matrix above, test on both
targets before merging:

1. **Local sanity check** — paste the diagram into the [Mermaid Live
   Editor](https://mermaid.live/) and confirm it renders syntactically.

2. **Push to a Gitea branch and view raw** — the `.md` in Gitea's web
   UI renders Mermaid in fenced ``` ```mermaid ``` ``` blocks
   automatically. Capture a screenshot of the rendered output.

3. **Push to the GitHub mirror** (after dual-remote push per
   `CONTRIBUTING.md`) and view on GitHub.com. Capture a screenshot.

4. **Compare side-by-side.** Specific things to look at:
   - Layout direction (LR vs TD) consistent
   - Subgraph borders + labels visible
   - Arrow styles match (solid, dotted, hatched)
   - Line breaks render where expected
   - Long labels don't truncate or overflow

5. **If parity fails**, simplify the diagram to use only features in the
   matrix above. Update the matrix with your new finding either way
   (success → add feature row; failure → add caveat row).

## Offline batch validation

Before relying on the live editor, you can validate the **entire corpus**
locally with the same Mermaid engine GitHub and Gitea run (headless Chrome
via `@mermaid-js/mermaid-cli`). This catches hard parse errors — the
`got 'PS'` / `got 'NEWLINE'` class in the caveats table — without a network
round-trip. The 2026-06-07 re-validation used this method:

1. `npm install @mermaid-js/mermaid-cli` in a scratch dir (pulls a
   Chrome-for-Testing build via Puppeteer; if Puppeteer's post-install
   can't unzip, extract `~/.cache/puppeteer/chrome/*/*-chrome-linux64.zip`
   manually).
2. Extract every fenced ` ```mermaid ` block from `docs/**/*.md` to its own
   `.mmd` file, preserving provenance.
3. Render each with `mmdc -i block.mmd -o /dev/null -p pptr.json` where
   `pptr.json` is `{ "args": ["--no-sandbox", "--disable-gpu",
   "--disable-dev-shm-usage"] }`. A non-zero exit + `Parse error on line N`
   pinpoints the failing block; the caret in the full output shows the
   exact token. Note the parser stops at the **first** error per block, so
   re-run after each fix — one diagram can hide several offenders.

## Known caveats

| Caveat | Notes |
|--------|-------|
| Very large diagrams (>40 nodes) render at small text on mobile | Split into multiple smaller diagrams; readers scrolling on phones lose context with dense diagrams |
| Mermaid theme defaults differ slightly between Gitea + GitHub | Mostly cosmetic (background contrast); both use light theme by default. Don't override theme in diagrams. |
| GitHub mirror has stricter CSP for some embedded styling | If you need custom styling, use the `classDef` mechanism (works on both) instead of inline `style` attributes |
| Some unicode characters render differently in node labels | Stick to ASCII + standard HTML entities for maximum portability |
| Unquoted `(` `)` `{` `}` `[` `]` inside a **flowchart** node label | The flowchart lexer reads them as shape delimiters → hard parse error (`got 'PS'`). **Quote the whole label**: `Node["text <br/>(detail)"]`. Quoting is parity-verified and still renders `<br/>` as a line break, so the diagram looks identical. |
| `&lt;` / `&gt;` HTML entities inside **sequence-diagram message text** | The sequence grammar is distinct from the flowchart grammar and rejects these entities → `got 'NEWLINE'` — even though flowchart labels accept `&lt;…&gt;` fine. Use **literal** `<…>` in sequence messages. (Asymmetry confirmed 2026-06-07.) |
| `;` semicolon inside **sequence-diagram message text** | Parsed as a statement separator, splitting the message into a second malformed statement → `got 'NEWLINE'`. Use `,` or "then" instead. A literal `<` (e.g. `<500ms`) inside a `note` is fine — only `actor->>actor:` *messages* are affected. |

## Capturing the screenshots

When this document was first authored (2026-05-17 modernization pass),
render parity was confirmed via:

- Gitea: `https://git.ipnode.org/<account>/powernode-system/src/branch/develop/docs/ARCHITECTURE.md` rendered in the web UI
- GitHub: `https://github.com/nodealchemy/powernode-system/blob/master/docs/ARCHITECTURE.md` rendered on github.com

Reference screenshots were captured for the 7 ARCHITECTURE.md diagrams
plus 3 representative samples (CONTAINER_RUNTIMES Phase 1 Docker
handshake, federation/NETWORK_TRUST sovereign auth handshake,
agent-internals fw-cfg discovery cascade). Screenshots are NOT
committed to the repo (per the no-rendered-images rule); store them in
the team's shared drive for reference.

## When to update this document

- Adding a Mermaid feature not in the matrix → add a row after verification
- Discovering a render mismatch → add a caveat row + a workaround
- Major Mermaid version bump on either target → re-test the full matrix

## Related

- [`README.md`](./README.md) — verification harness overview
- [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) §Mermaid convention — authoring guidelines
