#!/usr/bin/env bash
# S3 benchmark: Zee3, MinIO and RustFS, one at a time, each on CPUs 0-1 with 2 GiB,
# warp on CPUs 2-3, single drive each, same workloads.
#   ./run.sh [round]      results go to results-<round>.txt
set -euo pipefail
cd "$(dirname "$0")"
ROUND=${1:-1}
OUT=results-$ROUND.txt
NET=s3bench
AK=benchadmin
SK=bench-secret-12345
DATA=/var/tmp/s3bench-data
ZEE3_IMAGE=${ZEE3_IMAGE:-terrificci/zee3:1.0.0}
docker network create $NET >/dev/null 2>&1 || true
: > "$OUT"

start() { # name
  docker rm -f s3 >/dev/null 2>&1 || true
  sudo rm -rf "$DATA" 2>/dev/null || rm -rf "$DATA"
  mkdir -p "$DATA" && chmod 777 "$DATA"
  local common=(-d --name s3 --network $NET --cpuset-cpus 0,1 --memory 2g -v "$DATA:/data")
  case "$1" in
    zee3) docker run "${common[@]}" -e ZEE3_ACCESS_KEY=$AK -e ZEE3_SECRET_KEY=$SK -e RUST_LOG=warn "$ZEE3_IMAGE" >/dev/null ;;
    minio) docker run "${common[@]}" -e MINIO_ROOT_USER=$AK -e MINIO_ROOT_PASSWORD=$SK pgsty/minio:latest server /data >/dev/null ;;
    rustfs) docker run "${common[@]}" -e RUSTFS_ACCESS_KEY=$AK -e RUSTFS_SECRET_KEY=$SK -e RUSTFS_VOLUMES=/data -e RUSTFS_ADDRESS=0.0.0.0:9000 rustfs/rustfs:latest >/dev/null ;;
  esac
  for _ in $(seq 60); do
    if docker run --rm --network $NET curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' http://s3:9000/ 2>/dev/null | grep -qE '^(200|403|400)$'; then return 0; fi
    sleep 1
  done
  echo "$1 did not start"; docker logs s3 | tail -20; exit 1
}

warp() { # label args...
  local label=$1; shift
  local log
  log=$(docker run --rm --network $NET --cpuset-cpus 2,3 quay.io/minio/warp:latest "$@" \
    --host s3:9000 --access-key $AK --secret-key $SK --quiet 2>&1 || true)
  local mem
  mem=$(docker stats --no-stream --format '{{.MemUsage}}' s3 | cut -d/ -f1 | tr -d ' ')
  local line
  line=$(printf '%s\n' "$log" | grep -E 'Average: ' | head -n 3 | sed 's/^ *\* *//' | tr '\n' ' ')
  printf '%-7s %-22s %s mem=%s\n' "$SERVER" "$label" "$line" "$mem" | tee -a "$OUT"
}

for SERVER in zee3 minio rustfs; do
  start $SERVER
  warp put-1MiB put --obj.size 1MiB --concurrent 16 --duration 40s --bucket b-put
  warp get-1MiB get --obj.size 1MiB --objects 500 --concurrent 16 --duration 40s --bucket b-get
  warp put-16KiB put --obj.size 16KiB --concurrent 32 --duration 40s --bucket b-small
  warp get-16KiB get --obj.size 16KiB --objects 2000 --concurrent 32 --duration 40s --bucket b-gsmall
  warp mixed-1MiB mixed --obj.size 1MiB --objects 300 --concurrent 16 --duration 40s --bucket b-mixed
  warp stat-16KiB stat --obj.size 16KiB --objects 1000 --concurrent 32 --duration 30s --bucket b-stat
  docker rm -f s3 >/dev/null
done
sudo rm -rf "$DATA" 2>/dev/null || rm -rf "$DATA"
echo "done: $OUT"
