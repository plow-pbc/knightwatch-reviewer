# Plow — Product Context

**Stage:** Early-stage agent platform, moving fast. Small user base; rigor should match that — favor clean designs over hardening edge cases.

**What it is:** A general wrapper that gives sandboxed agents narrow, permission-gated access to cloud services and on-device capabilities. Three tiers: **Plow API** (`api/`, FastAPI on AWS) + **Phoenix macOS app** (`app/Phoenix/` Swift + `app/plowd/` Python daemon, runs an Alpine VM with the agent runtime inside) + **Plow CLI** (`cli/`, the agent's tool surface). The current agent runtime is OpenClaw, but the wrapper is designed to be runtime-agnostic. Connectors and channels are pluggable and the inventory shifts — read `README.md` for the current list. ClawHub (`clawhub.ai`) is a *separate* service that hosts agent skills; the marketplace UI in this repo calls its API.

**Authoritative guidance lives in two files; read them first:**
- `AGENTS.md` — coding stance (clean replacement over migration code, no dual-write paths, no compatibility shims, complexity-debt aversion, scheduler-selection rules, issue-filing conventions for `cncorp/plow`).
- `docs/architecture/file-taxonomy.md` — every file is exactly one of (a) **upstream agent runtime** (currently OpenClaw, pulled in at VM build time; we have no edit access to that source — fixes there mean pinning a different version or PRing upstream, not editing in this tree), (b) **Plow wrapper code we own**, or (c) **per-install user state**. Confusing the categories is "the source of nearly every 'broken on upgrade' or 'shipped user data' incident." A pre-commit guard (`scripts/check_protected_paths.py`) enforces it.

**Architectural commitments worth flagging when a PR breaks them:**
- The agent never holds raw OAuth tokens — it sees narrow CLI tools only. PRs that leak token material into the agent surface are a security regression.
- `plowd` is the host/guest control plane. Code that talks to the VM directly (e.g. SSH from a service that already has a plowd dependency) splits authority — route through plowd instead.
- File-taxonomy violations are blocking. The two recurring failure modes: (i) per-install (c) state shipped inside `Plow.app/Contents/Resources/`, (ii) attempts to "fix" upstream (a) behavior by patching around it in this tree. When (a) is the wrong shape, the answer is to wrap, version-pin, or PR upstream — never edit upstream-owned paths locally. The guard catches the obvious cases; review attention catches the non-obvious ones.
- Treat `AGENTS.md` "Product Stage" and "Complexity Debt" sections as load-bearing review criteria. Heuristic accretion (one keyword exception, then another) is the canonical failure mode to push back on.

**Review posture:**
- The architecture specialist is allowed and encouraged to file non-blocking "open an issue before X" findings when a design decision is fine today but will bite at a known transition.
- For roadmap-flavored findings, link to the relevant doc in `docs/architecture/` or `plans/` rather than asserting the roadmap from memory — specifics drift faster than this file is updated.

**Update cadence:** Edit when a tier moves (e.g. `app/` restructures), the file-taxonomy rules change, or `AGENTS.md` shifts a load-bearing stance.
