#!/usr/bin/env bash
# Resource footprint of zee3, MinIO and RustFS on a shared machine: no CPU or
# memory limits, CPU use while idle, CPU per object while writing, and memory
# (anonymous, i.e. the process's own, not the page cache) as objects pile up.
#   ./footprint.sh [stages] [servers...]   results go to footprint-<date>.txt
#   ZEE3_IMAGE=... ZEE3_ENV=ZEE3_META_CACHE_MB=64 ./footprint.sh 6 zee3
set -euo pipefail
cd "$(dirname "$0")"
STAGES=${1:-4}; shift || true
SERVERS=${*:-zee3 minio rustfs}
OUT=footprint-$(date +%Y%m%d-%H%M).txt
NET=s3bench AK=benchadmin SK=bench-secret-12345 DATA=/var/tmp/s3bench-data
ZEE3_IMAGE=${ZEE3_IMAGE:-terrificci/z3:latest}
docker network create $NET >/dev/null 2>&1 || true
: > "$OUT"

cg() { echo "/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' s3).scope"; }
cpu_us() { awk '/^usage_usec/ {print $2}' "$(cg)/cpu.stat"; }
anon_mib() { awk '/^anon / {printf "%d", $2/1048576}' "$(cg)/memory.stat"; }
file_mib() { awk '/^file / {printf "%d", $2/1048576}' "$(cg)/memory.stat"; }
idle() { # seconds -> cpu percent of one core
  local a b; a=$(cpu_us); sleep "$1"; b=$(cpu_us)
  awk -v a="$a" -v b="$b" -v s="$1" 'BEGIN {printf "%.2f", (b-a)/1e6/s*100}'
}
line() { printf '%-7s %s\n' "$SERVER" "$*" | tee -a "$OUT"; }

start() {
  docker rm -f s3 >/dev/null 2>&1 || true
  sudo rm -rf "$DATA" 2>/dev/null || rm -rf "$DATA"
  mkdir -p "$DATA" && chmod 777 "$DATA"
  local common=(-d --name s3 --network $NET -v "$DATA:/data")
  case "$1" in
    zee3)
      local extra=() kv
      IFS=',' read -ra kvs <<< "${ZEE3_ENV:-}"
      for kv in "${kvs[@]}"; do [ -n "$kv" ] && extra+=(-e "$kv"); done
      docker run "${common[@]}" -e ZEE3_ACCESS_KEY=$AK -e ZEE3_SECRET_KEY=$SK -e RUST_LOG=warn "${extra[@]}" "$ZEE3_IMAGE" >/dev/null ;;
    minio) docker run "${common[@]}" -e MINIO_ROOT_USER=$AK -e MINIO_ROOT_PASSWORD=$SK pgsty/minio:latest server /data >/dev/null ;;
    rustfs) docker run "${common[@]}" -e RUSTFS_ACCESS_KEY=$AK -e RUSTFS_SECRET_KEY=$SK -e RUSTFS_VOLUMES=/data -e RUSTFS_ADDRESS=0.0.0.0:9000 rustfs/rustfs:latest >/dev/null ;;
  esac
  for _ in $(seq 60); do
    if docker run --rm --network $NET curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' http://s3:9000/ 2>/dev/null | grep -qE '^(200|403|400)$'; then return 0; fi
    sleep 1
  done
  echo "$1 did not start"; exit 1
}

for SERVER in $SERVERS; do
  start $SERVER
  sleep 15
  line "start: idle cpu $(idle 60)% of a core, memory $(anon_mib) MiB (+$(file_mib) MiB page cache)"
  total=0
  for stage in $(seq "$STAGES"); do
    a=$(cpu_us)
    log=$(docker run --rm --network $NET quay.io/minio/warp:latest put --obj.size 4KiB --concurrent 16 --duration 60s \
      --noclear --bucket fpbench --host s3:9000 --access-key $AK --secret-key $SK --quiet 2>&1 || true)
    b=$(cpu_us)
    rate=$(printf '%s\n' "$log" | grep -m1 -oE 'Average: [0-9.]+ MiB/s, [0-9.]+ obj/s' | grep -oE '[0-9.]+ obj/s' | cut -d" " -f1 || true)
    n=$(awk -v r="${rate:-0}" 'BEGIN {printf "%d", r*60}')
    total=$((total + n))
    per=$(awk -v a="$a" -v b="$b" -v n="$n" 'BEGIN {if (n>0) printf "%.3f", (b-a)/1e3/n; else print "?"}')
    line "after $total objects: ${rate:-?} obj/s, ${per} ms cpu/object, memory $(anon_mib) MiB (+$(file_mib) MiB cache), idle cpu $(idle 30)%"
  done
  docker rm -f s3 >/dev/null
done
sudo rm -rf "$DATA" 2>/dev/null || rm -rf "$DATA"
echo "done: $OUT"
