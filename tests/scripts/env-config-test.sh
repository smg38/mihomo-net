#!/usr/bin/env bash
# =============================================================================
# env-config-test.sh — regression tests for env loading and D configuration.
# Version: 3.3.0
# Date:    2026-11-07
# Author:  @smg38
# Run from the repository root:
#   bash tests/scripts/env-config-test.sh
#
# The fixtures are created under a temporary directory and removed on exit.
# =============================================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$PROJECT_ROOT/deploy/lib/env.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# The instance file must override matching common parameters.
printf 'VALUE=base\n' > "$tmp_dir/params.env"
printf 'VALUE=instance\n' > "$tmp_dir/instance.env"
load_env_file_literal "$tmp_dir/params.env"
load_env_file_literal "$tmp_dir/instance.env"
[[ "$VALUE" == instance ]] || { echo "instance override failed" >&2; exit 1; }

# Reject shell-style references and command substitutions in values.
for invalid_value in '${OTHER}' '$OTHER' '$(printf bad)'; do
    printf 'VALUE=%s\n' "$invalid_value" > "$tmp_dir/params.env"
    if load_env_file_literal "$tmp_dir/params.env"; then
        echo "variable interpolation was accepted: $invalid_value" >&2
        exit 1
    fi
done

# Comments may contain dollar signs without counting as substitutions.
printf '# ${COMMENT} is ignored\nVALUE=literal # $COMMENT\n' > "$tmp_dir/params.env"
load_env_file_literal "$tmp_dir/params.env"
[[ "$VALUE" == literal ]] || { echo "literal comments were not handled" >&2; exit 1; }

# Validate an allowed D overlay, then make sure unknown settings are rejected.
cat > "$tmp_dir/D2.env" <<'EOF'
IP_D=192.168.10.90
PORT_D=7893
SECRET_KEY_D=unique
EOF
validate_d_instance_file "$tmp_dir/D2.env"

printf 'TYPO=unexpected\n' >> "$tmp_dir/D2.env"
if validate_d_instance_file "$tmp_dir/D2.env"; then
    echo "unknown instance setting was accepted" >&2
    exit 1
fi

# Independent connection lists control B and C accounts and D proxy routes.
cat > "$tmp_dir/template.env" <<'EOF'
D_TO_B_INSTANCES="D2"
D_TO_C_INSTANCES="D"
PORT_B=22443
PORT_C=8443
FLOW_AB=xtls-rprx-vision
FLOW_USERS=xtls-rprx-vision
LISTEN_B=vless
LISTEN_C=vless
USERS_C=""
EOF
export UUID_DB_D=11111111-1111-4111-8111-111111111111
export UUID_DB_D2=22222222-2222-4222-8222-222222222222
export UUID_DC_D=33333333-3333-4333-8333-333333333333
export UUID_DC_D2=44444444-4444-4444-8444-444444444444

"$PROJECT_ROOT/scripts/templater.sh" -e "$tmp_dir/template.env" \
    -o "$tmp_dir/config_B.yaml" "$PROJECT_ROOT/template/config_B.yaml.j3"
"$PROJECT_ROOT/scripts/templater.sh" -e "$tmp_dir/template.env" \
    -o "$tmp_dir/config_C.yaml" "$PROJECT_ROOT/template/config_C.yaml.j3"

grep -q '^      - username: serverD2$' "$tmp_dir/config_B.yaml"
! grep -q '^      - username: serverD$' "$tmp_dir/config_B.yaml"
grep -q '22222222-2222-4222-8222-222222222222' "$tmp_dir/config_B.yaml"
! grep -q '11111111-1111-4111-8111-111111111111' "$tmp_dir/config_B.yaml"
grep -q '^      - username: serverD$' "$tmp_dir/config_C.yaml"
! grep -q '^      - username: serverD2$' "$tmp_dir/config_C.yaml"
grep -q '33333333-3333-4333-8333-333333333333' "$tmp_dir/config_C.yaml"
! grep -q '44444444-4444-4444-8444-444444444444' "$tmp_dir/config_C.yaml"

# D2 is allowed to use B but not C; its generated config must match that policy.
cat >> "$tmp_dir/template.env" <<'EOF'
INSTANCE_ID=D2
D_TO_B_ENABLED=true
D_TO_C_ENABLED=false
IP_B=198.51.100.10
IP_C=203.0.113.20
PORT_D=7893
DNS_PORT=1053
SERVERNAME=example.com
FINGERPRINT=chrome
PUBLIC_KEY_B=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHORT_ID_B=12345678
PUBLIC_KEY_C=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHORT_ID_C=87654321
SECRET_KEY_D=example
GEO_MODE=local
EOF
"$PROJECT_ROOT/scripts/templater.sh" -e "$tmp_dir/template.env" \
    -o "$tmp_dir/config_D2.yaml" "$PROJECT_ROOT/template/config_D.yaml.j3"
grep -q 'name: "to-serverB"' "$tmp_dir/config_D2.yaml"
! grep -q 'name: "to-serverC"' "$tmp_dir/config_D2.yaml"
grep -A6 'name: PROXY' "$tmp_dir/config_D2.yaml" | grep -q 'to-serverB'
! grep -A6 'name: PROXY' "$tmp_dir/config_D2.yaml" | grep -q 'to-serverC'

echo "env config tests passed"
