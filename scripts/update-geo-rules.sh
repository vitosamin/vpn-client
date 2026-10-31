#!/usr/bin/env bash
# Regenerates the bundled RU geo lists in assets/geo/.
#
# The app ships the RU country lists inside the APK (assets/geo/ru_*.txt) and turns them into a
# plain sing-box rule (domains, domain suffixes and IP CIDRs, outbound direct). GitHub is not
# needed at runtime: the lists are already in the app and in the config it builds.
#
# Sources, as used by hiddify-core for its remote rule-sets:
#   https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geosite-ru.srs
#   https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country/geoip-ru.srs
#
# The .srs files are sing-box binary rule-sets; "sing-box rule-set decompile" turns them into the
# source format, which is then flattened into one item per line. A sing-box release binary is
# needed for the decompile step and is downloaded on demand (override with SING_BOX=/path/to/sing-box).
#
# Requirements: bash, curl, python3, and a sing-box binary (any recent 1.11+ release).
#
# Usage: scripts/update-geo-rules.sh [--check]
#   --check   only report whether the bundled files match a fresh download; writes nothing.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
geo_dir="$repo_root/assets/geo"
geo_base="https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set/country"
sing_box_version="1.13.0"
sing_box_url="https://github.com/SagerNet/sing-box/releases/download/v${sing_box_version}/sing-box-${sing_box_version}-linux-amd64.tar.gz"
check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# 1. fetch the rule-sets
for name in geosite-ru geoip-ru; do
  url="$geo_base/$name.srs"
  code="$(curl -fsSL -o "$work_dir/$name.srs" -w '%{http_code}' "$url")"
  size="$(stat -c %s "$work_dir/$name.srs")"
  if [[ "$code" != "200" || "$size" -lt 1024 ]]; then
    echo "download failed: $url (HTTP $code, $size bytes)" >&2
    exit 1
  fi
  echo "fetched $name.srs: $size bytes ($(sha256sum "$work_dir/$name.srs" | cut -d' ' -f1))"
done

# 2. a sing-box binary to decompile them
sing_box="${SING_BOX:-}"
if [[ -z "$sing_box" ]]; then
  if command -v sing-box >/dev/null 2>&1; then
    sing_box="$(command -v sing-box)"
  else
    echo "downloading sing-box ${sing_box_version} for the decompile step"
    curl -fsSL -o "$work_dir/sing-box.tar.gz" "$sing_box_url"
    tar -xzf "$work_dir/sing-box.tar.gz" -C "$work_dir"
    sing_box="$work_dir/sing-box-${sing_box_version}-linux-amd64/sing-box"
  fi
fi
"$sing_box" version | head -1

for name in geosite-ru geoip-ru; do
  "$sing_box" rule-set decompile "$work_dir/$name.srs" -o "$work_dir/$name.json"
done

# 3. flatten to one item per line
python3 - "$work_dir" "$geo_dir" "$check_only" <<'PY'
import json
import pathlib
import sys

work_dir, geo_dir, check_only = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "true"

def items(name, key):
    data = json.loads((work_dir / f"{name}.json").read_text())
    out = []
    for rule in data["rules"]:
        out.extend(rule.get(key, []))
    return out

targets = {
    "ru_domain.txt": sorted(set(items("geosite-ru", "domain"))),
    "ru_domain_suffix.txt": sorted(set(items("geosite-ru", "domain_suffix"))),
    "ru_ip_cidr.txt": sorted(set(items("geoip-ru", "ip_cidr"))),
}

if not check_only:
    geo_dir.mkdir(parents=True, exist_ok=True)

stale = False
for file_name, values in targets.items():
    content = "".join(f"{value}\n" for value in values)
    path = geo_dir / file_name
    if check_only:
        same = path.is_file() and path.read_text() == content
        stale |= not same
        print(f"{'ok  ' if same else 'STALE'} {file_name}: {len(values)} items")
    else:
        path.write_text(content)
        print(f"wrote {file_name}: {len(values)} items, {len(content.encode())} bytes")

if check_only and stale:
    sys.exit(1)
PY

if ! $check_only; then
  echo "done, see assets/geo/"
fi
