#!/usr/bin/env bash
# S3 conformance: MinIO Mint and the ceph/s3-tests subset against one z3
# image (docs/conformance.md). Runs on the bench server, never the laptop.
#   ./conformance.sh [--build] [all|mint|s3tests]
#     --build   build the repository (..) into $Z3_IMAGE first
#   Z3_IMAGE=terrificci/z3:1.0.3 ./conformance.sh     test an existing image
# Prints a summary per suite and exits 1 when anything in the subset fails
# (excluded failures are listed with their reason). Results: $OUT.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD
CONF=$HERE/conformance
WHAT=all
BUILD=0
for a in "$@"; do
  case "$a" in
    --build) BUILD=1 ;;
    all | mint | s3tests) WHAT=$a ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
  esac
done
Z3_IMAGE=${Z3_IMAGE:-z3bench:conformance}
MINT_IMAGE=${MINT_IMAGE:-minio/mint:edge}
S3TESTS_DIR=${S3TESTS_DIR:-$HOME/s3-tests}
S3TESTS_REF=${S3TESTS_REF:-5b39871}
OUT=${OUT:-$HERE/conformance-results}
NET=z3conformance
NAME=z3conformance
AK=conformadmin
SK=conform-secret-12345
docker network create $NET >/dev/null 2>&1 || true
mkdir -p "$OUT"
# Mint uploads a few GiB; a full disk turns into InternalError everywhere.
if [ "$(df --output=avail -k "$OUT" | tail -1)" -lt $((6 * 1024 * 1024)) ]; then
  echo "less than 6 GiB free under $OUT: free some space first"; exit 1
fi

if [ $BUILD = 1 ]; then
  DOCKER_BUILDKIT=1 docker build -t "$Z3_IMAGE" .. >"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
fi

stop() { # with its anonymous /data volume (Mint writes gigabytes)
  docker rm -fv $NAME >/dev/null 2>&1 || true
}

start() { # a fresh node; SigV2 on, since Mint and s3-tests exercise it
  stop
  docker run -d --name $NAME --network $NET -e Z3_ACCESS_KEY=$AK -e Z3_SECRET_KEY=$SK \
    -e Z3_GC_INTERVAL=0 -e Z3_ENABLE_SIGV2=true -e RUST_LOG=warn "$Z3_IMAGE" >/dev/null
  for _ in $(seq 60); do
    if docker exec $NAME z3 healthcheck >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "z3 did not start"; docker logs $NAME | tail -20; exit 1
}

trap stop EXIT
status=0

if [ "$WHAT" != s3tests ]; then
  echo "== MinIO Mint ($MINT_IMAGE)"
  start
  # Mint writes its logs as root: clear them from inside a container.
  docker run --rm -v "$OUT:/out" --entrypoint rm "$MINT_IMAGE" -rf /out/mint >/dev/null 2>&1 || true
  mkdir -p "$OUT/mint"
  # RUN_ON_FAIL: minio-go keeps going after a failure, so every failure is reported.
  docker run --rm --network $NET -e SERVER_ENDPOINT=$NAME:9000 -e ACCESS_KEY=$AK -e SECRET_KEY=$SK \
    -e ENABLE_HTTPS=0 -e MINT_MODE=full -e RUN_ON_FAIL=1 -v "$OUT/mint:/mint/log" "$MINT_IMAGE" >"$OUT/mint.out" 2>&1 || true
  python3 "$CONF/mint_summary.py" "$OUT/mint/log.json" "$CONF/mint-exclude.txt" | tee "$OUT/mint-summary.txt" || status=1
fi

if [ "$WHAT" != mint ]; then
  echo "== ceph/s3-tests ($S3TESTS_REF)"
  if [ ! -d "$S3TESTS_DIR/.git" ]; then
    git clone -q https://github.com/ceph/s3-tests.git "$S3TESTS_DIR"
  fi
  git -C "$S3TESTS_DIR" checkout -q "$S3TESTS_REF"
  # The test runner with its requirements (cached; rebuilt when they change).
  tag="z3conformance-s3tests:$(sha256sum "$S3TESTS_DIR/requirements.txt" | cut -c1-12)"
  if ! docker image inspect "$tag" >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    cp "$S3TESTS_DIR/requirements.txt" "$tmp/"
    printf 'FROM python:3.12-slim\nCOPY requirements.txt /tmp/\nRUN pip install -q --no-cache-dir -r /tmp/requirements.txt\n' >"$tmp/Dockerfile"
    docker build -q -t "$tag" "$tmp" >/dev/null
    rm -rf "$tmp"
  fi
  start
  rm -f "$OUT/s3tests.xml" "$OUT/s3tests.conf"
  docker run --rm --network $NET -v "$S3TESTS_DIR:/s3t:ro" -v "$CONF:/cfg:ro" -v "$OUT:/out" -w /s3t \
    -e PYTHONPATH=/cfg -e S3TEST_CONF=/out/s3tests.conf "$tag" sh -c "
      python /cfg/setup_users.py http://$NAME:9001 $NAME 9000 $AK $SK /out/s3tests.conf >/dev/null &&
      python -m pytest s3tests/functional/test_s3.py s3tests/functional/test_headers.py -q -p no:cacheprovider \
        -p s3tests_subset -m \"\$(grep -v '^#' /cfg/s3tests-markers.txt | tr '\n' ' ')\" --junitxml=/out/s3tests.xml" \
    >"$OUT/s3tests.out" 2>&1 || true
  tail -1 "$OUT/s3tests.out"
  python3 "$CONF/junit_summary.py" "$OUT/s3tests.xml" --fails | tee "$OUT/s3tests-summary.txt"
  head -1 "$OUT/s3tests-summary.txt" | grep -q ' failure=0 error=0 ' || status=1
fi

stop
[ $status = 0 ] && echo "conformance: the subset passes" || echo "conformance: FAILURES in the subset"
exit $status
