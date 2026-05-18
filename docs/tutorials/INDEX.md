# Tutorial Decision Tree

Not sure where to start? Pick the leaf that matches your goal and follow
the path back up to know which tutorials precede it.

```mermaid
flowchart TD
    Start([What are you trying to do?]):::start

    Start --> Q1{Have you booted a<br/>Powernode node before?}
    Q1 -->|No| T01[Tutorial 01<br/>First boot]:::leaf
    Q1 -->|Yes| Q2{What's next?}

    Q2 -->|Run my own code<br/>as a module| T02[Tutorial 02<br/>Your first custom module]:::leaf
    Q2 -->|Manage containers| Q3{Single host or<br/>cluster?}
    Q2 -->|Production hardening| Q4{What concern?}
    Q2 -->|Scale beyond<br/>one cluster| Q5{Single account<br/>or federated?}
    Q2 -->|Manage fleet as code| T10[Tutorial 10<br/>GitOps-managed fleet]:::leaf
    Q2 -->|Handle traffic bursts| T08[Tutorial 08<br/>Instance pools]:::leaf
    Q2 -->|Ship custom OS images| T12[Tutorial 12<br/>Disk image CI]:::leaf

    Q3 -->|Single host| T03[Tutorial 03<br/>Docker runtime]:::leaf
    Q3 -->|K8s cluster| T04[Tutorial 04<br/>K3s cluster]:::leaf

    Q4 -->|Security upgrades| T07[Tutorial 07<br/>CVE response]:::leaf
    Q4 -->|Rolling deploys| T06[Tutorial 06<br/>Rolling upgrade]:::leaf
    Q4 -->|Catch intruders| T09[Tutorial 09<br/>Honeypot canary]:::leaf

    Q5 -->|Single account| T05[Tutorial 05<br/>Multi-cluster K3s]:::leaf
    Q5 -->|Federated| T11[Tutorial 11<br/>Multi-region federation]:::leaf

    classDef start fill:#1e3a5f,stroke:#fff,color:#fff;
    classDef leaf fill:#0d4f3c,stroke:#fff,color:#fff;
```

## Reading the tree

- **Tutorial 01** is the universal entry point — everything else assumes a
  working single-node boot. If you haven't done that yet, start there.
- Tutorials are dependency-ordered: each declares what came before in its
  "Builds on" header. If you land on Tutorial 07 (CVE response) without
  having done 02 + 03 + 06, the tutorial tells you where to backfill.
- Numbered order isn't strictly required — branches are independent. You
  can go 01 → 02 → 03 → 04 → 11 (skipping 05–10) if federation is your
  immediate goal.

## Recommended learning paths

**"I want a working development loop"** (~45 min):
01 → 02 → 03

**"I want to run a production K8s cluster"** (~2 h):
01 → 02 → 03 → 04 → 06 → 07

**"I want a multi-region federated platform"** (~4 h):
01 → 02 → 03 → 04 → 05 → 10 → 11

**"I want to operate the platform autonomously"** (~3 h):
01 → 02 → 06 → 09 → 10

## See also

- [`README.md`](./README.md) — the full sequence with builds-on graph
- [`../SMOKE_TEST.md`](../SMOKE_TEST.md) — what gets validated at the platform layer
- [`../USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — what works / what doesn't for 14 NodeInstance scenarios
