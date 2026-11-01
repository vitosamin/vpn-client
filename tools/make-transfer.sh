#!/bin/bash
# Собирает пакет для переноса проекта на другую машину (см. TRANSFER.md).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT=${1:-"$ROOT/transfer"}
APP="$ROOT/app"

echo "== очистка $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "== git bundle (main + все ветки + теги)"
mkdir -p "$OUT/git"
# worktree-ветки в bundle не входят автоматически — перечисляем refs
cd "$APP"
git bundle create "$OUT/git/vitosamin.bundle" --all 2>/dev/null
cd "$ROOT"

echo "== документация и сервер (без секретов, логов и кэша)"
cp -a docs "$OUT/"
cp -a server "$OUT/"
rm -rf "$OUT/server/.env" "$OUT/server/logs" "$OUT/server/data" "$OUT/server/run.pid"
find "$OUT/server" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT/server" -name '*.pyc' -delete 2>/dev/null || true
mkdir -p "$OUT/tools"
cp -a tools/serve-dist.sh tools/make-transfer.sh "$OUT/tools/" 2>/dev/null || true
cp -a TRANSFER.md README.md ROADMAP.md .gitignore "$OUT/"

echo "== APK: в пакет не кладём (отдельная раздача /vpn/), только контрольные суммы"
mkdir -p "$OUT/dist"
cp -a dist/SHA256SUMS.txt "$OUT/dist/" 2>/dev/null || true

echo "== секреты (ОТДЕЛЬНО, не для git)"
mkdir -p "$OUT/secrets"
cp -a secrets/release.jks secrets/keystore-password.txt "$OUT/secrets/" 2>/dev/null || true
chmod 600 "$OUT/secrets/"* 2>/dev/null || true

echo "== контрольные суммы"
cd "$OUT"
find . -type f ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt
cd "$ROOT"

echo "== архив"
tar -czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")"
ls -lh "$OUT.tar.gz"
echo "готово: $OUT.tar.gz"
