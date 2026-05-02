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
#           counter-arguments H2 + per-angle critic block)
#           $SPECIALISTS_DIR/missed.md ("## Missed findings" section
#           if present in critic.md; written verbatim)
#
# Section grammar in critic.md:
#   ### [<angle>] Finding N — <status>     ← per-angle finding section
#   ## Missed findings (if any)            ← global missed-findings sink
#   ## <anything else>                     ← treated as section terminator

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
        # Per-angle finding section
        /^### \[[a-z][a-z-]*\] Finding/ {
            flush()
            line = $0
            sub(/^### \[/, "", line)
            sub(/\].*/, "", line)
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
    ' "$critic_md"

    # Pass 2: for each .angle-buf, append to specialists/<angle>.md under
    # a "## Critic counter-arguments" H2. Replaces the file (which is
    # typically a symlink to the agent's output.md) with a regular file
    # containing original + critic-block. Skip + warn when the specialist
    # file is absent.
    local f angle target original
    for f in "$specialists_dir"/*.angle-buf; do
        [ -e "$f" ] || continue
        angle=$(basename "$f" .angle-buf)
        target="$specialists_dir/${angle}.md"
        if [ ! -e "$target" ]; then
            echo "split_critic_to_specialists: no specialist file for [$angle] — skipping" >&2
            rm -f "$f"
            continue
        fi
        original=$(cat "$target")
        rm -f "$target"
        {
            printf '%s\n\n---\n\n## Critic counter-arguments\n\n' "$original"
            cat "$f"
            printf '\n'
        } > "$target"
        rm -f "$f"
    done
}
