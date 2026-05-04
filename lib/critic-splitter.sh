#!/usr/bin/env bash
# Sourceable helper for splitting critic.md by [<angle>] sections and
# appending each section to the corresponding specialists/<angle>.md
# file. Single writer per phase per file — orchestrator runs this
# synchronously after the critic completes and before the aggregator
# (and Phase 2's go-deep tech-leads), so no race.
#
# split_critic_to_specialists CRITIC_MD SPECIALISTS_DIR
#   reads:  $CRITIC_MD
#   writes: $SPECIALISTS_DIR/<angle>.md (replaces with original + critic
#           per-angle resolution H2 + per-angle critic block)
#           $SPECIALISTS_DIR/critic.md (Generated probes from critic, routed here so
#           the aggregator picks them up alongside angle-specialist files)
#
# Section grammar in critic.md:
#   ### [<angle>] Finding N — <status>           ← legacy per-angle finding (back-compat)
#   ### [from: <angle>] Probe N                  ← new per-angle probe resolution
#   ## Generated probes                          ← critic-originated probes sink
#   ## <anything else>                           ← treated as section terminator

split_critic_to_specialists() {
    local critic_md="$1" specialists_dir="$2"
    if [ ! -s "$critic_md" ]; then
        echo "split_critic_to_specialists: $critic_md missing or empty — nothing to split" >&2
        return 0
    fi
    if [ ! -d "$specialists_dir" ]; then
        echo "split_critic_to_specialists: $specialists_dir does not exist" >&2
        return 1
    fi
    # Empty-output sentinel: the critic prompt instructs the model to
    # emit `No probes.` on its own line when every specialist returned
    # nothing AND the generation pass surfaced nothing. Recognized here
    # as a valid clean-empty critic so aggregation proceeds; without
    # this carve-out, the probe-content gate below would abort an
    # all-clean review.
    if grep -qE '^No probes\.$' "$critic_md"; then
        return 0
    fi

    # Pass 1: walk critic.md, accumulate per-angle blocks into <angle>.angle-buf
    # files. The "## Missed findings" section in critic.md stays in critic.md —
    # the aggregator reads it from there directly (per prompts/aggregator.md);
    # extracting it to a separate sink would duplicate the contract.
    awk -v out_dir="$specialists_dir" '
        function flush() {
            if (current_angle != "" && length(buf) > 0) {
                f = out_dir "/" current_angle ".angle-buf"
                print buf >> f
                close(f)
                buf = ""
            }
        }
        # Per-angle finding/probe section (legacy Finding or new Probe, with optional "from: " prefix)
        /^### \[(from: )?[a-z][a-z-]*\] (Finding|Probe)/ {
            flush()
            line = $0
            sub(/^### \[/, "", line)
            sub(/\].*/, "", line)
            sub(/^from: /, "", line)
            current_angle = line
            buf = $0
            next
        }
        # Any H2 (including "## Missed findings") ends the active angle.
        /^## / {
            flush()
            current_angle = ""
            next
        }
        # Body lines accumulate to whichever angle is active.
        {
            if (current_angle != "") {
                if (length(buf) > 0) buf = buf "\n" $0
                else                 buf = $0
            }
        }
        END { flush() }
    ' "$critic_md" || return 1

    # Pass 1.5: extract "## Generated probes" section to specialists/critic.md.
    awk -v out_file="$specialists_dir/critic.md" '
        /^## Generated probes/ { in_gen = 1; next }
        /^## / && in_gen { in_gen = 0 }
        in_gen { print > out_file }
    ' "$critic_md" || return 1

    # Probe-contract gate: critic_md was non-empty (checked at top), but if
    # pass-1 produced no .angle-buf files AND pass-1.5 produced no real
    # probe block in specialists/critic.md, the critic returned malformed
    # output. Silent pass-through would demote a critic-resolved blocker
    # to nothing in the rendered review.
    #
    # Why grep `^### Probe ` instead of `[ -s ... ]`: an empty
    # `## Generated probes` section (header only, blank line under it)
    # writes a whitespace-only critic.md via awk's `print > out_file`.
    # Byte-non-empty would let that pass the gate; meaningful-empty
    # requires a real probe header. Same shape token used in
    # probe-schema.md § Generated probes (`### Probe N`).
    local angle_bufs=( "$specialists_dir"/*.angle-buf )
    if [ ! -e "${angle_bufs[0]}" ] && ! grep -qE '^### Probe ' "$specialists_dir/critic.md" 2>/dev/null; then
        echo "split_critic_to_specialists: critic output non-empty but produced no [from: <angle>] Probe blocks and no '### Probe N' generated-probe blocks — fail-loud (silent drop would demote critic-resolved blockers)" >&2
        return 1
    fi

    # Pass 2: for each .angle-buf, append to specialists/<angle>.md under
    # a "## Critic counter-arguments" H2. Replaces the file (which is
    # typically a symlink to the agent's output.md) with a regular file
    # containing original + critic-block. Fail-loud when ANY target is
    # absent — return non-zero at end of pass. Production-wise the
    # partial state is unreachable (orchestrator aborts + rm -rf's
    # REPO_DIR on the non-zero return), but the smoke depends on
    # deterministic "valid splits process regardless of which angle
    # missed" semantics across alphabetic glob order, so we run the
    # whole loop. Net: 3 LOC of counter for deterministic smoke
    # behavior — pragmatic trade despite R14's Concise-Code framing.
    local missing_targets=0
    local f angle target original
    for f in "$specialists_dir"/*.angle-buf; do
        [ -e "$f" ] || continue
        angle=$(basename "$f" .angle-buf)
        target="$specialists_dir/${angle}.md"
        if [ ! -e "$target" ]; then
            echo "split_critic_to_specialists: no specialist file for [$angle] — fail-loud (critic resolved an unknown angle)" >&2
            rm -f "$f"
            missing_targets=$((missing_targets + 1))
            continue
        fi
        original=$(cat "$target") || return 1
        rm -f "$target"
        {
            printf '%s\n\n---\n\n## Critic counter-arguments\n\n' "$original"
            cat "$f"
            printf '\n'
        } > "$target" || return 1
        rm -f "$f"
    done
    [ "$missing_targets" -eq 0 ]
}
