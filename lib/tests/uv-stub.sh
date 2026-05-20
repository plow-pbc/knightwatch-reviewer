#!/usr/bin/env bash
# Test helper: writes a `uv` stub into the given bin dir for smokes
# that run install.sh. The stub fail-louds on unexpected argv (catches
# version-pin regression) and synthesizes a `vulture` binary on
# `tool install` (smoke can only succeed when install.sh fires it).

write_uv_stub() {
    local bin_dir="$1"
    cat > "$bin_dir/uv" <<STUB
#!/bin/bash
[ "\$1 \$2 \$3" = "tool install vulture==2.16" ] || { echo "uv stub: unexpected args: \$*" >&2; exit 1; }
cat > "$bin_dir/vulture" <<'V'
#!/bin/bash
echo "vulture 2.16"
V
chmod +x "$bin_dir/vulture"
STUB
    chmod +x "$bin_dir/uv"
}
