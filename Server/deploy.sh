#!/usr/bin/env bash
# 라즈베리파이로 Mac 에서 직접 배포.
#   1) linux/arm64 이미지 빌드 (Mac amd64/arm64 모두에서 cross-compile)
#   2) docker save → tar
#   3) scp 이미지 + docker-compose.yml → 원격 디렉토리
#   4) ssh 로 docker load + compose up -d (force-recreate)
#   5) 로컬/원격 tar 정리 + orphan 이미지 prune
#
# 사전 조건:
#   - Mac 에 Docker Desktop + buildx 설치 (docker buildx --version 으로 확인).
#   - 라즈베리파이에 Docker Engine + compose plugin 설치.
#   - ssh key 로그인 셋업 (passwordless 권장).
#   - Pi 의 REMOTE_BASE_DIR 에 .env / secrets/AuthKey_XXX.p8 가 이미 존재
#     (첫 배포 전 수동 scp + .env 작성 — `docs/ops/nunting-server.md` 참고).
#
# 사용법: `cd Server && ./deploy.sh`

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/.deploy.env" ]; then
    echo "ERROR: ${SCRIPT_DIR}/.deploy.env 가 없습니다." >&2
    echo "       .deploy.env.example 을 복사해 본인 Pi 정보로 채우세요." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/.deploy.env"

: "${REMOTE_USER:?REMOTE_USER 미설정}"
: "${REMOTE_HOST:?REMOTE_HOST 미설정}"
: "${REMOTE_BASE_DIR:?REMOTE_BASE_DIR 미설정}"

IMAGE_NAME="nunting-server"
IMAGE_TAG="local"
IMAGE_FILE="${IMAGE_NAME}.tar"
LOCAL_TAR="${SCRIPT_DIR}/${IMAGE_FILE}"

echo ""
echo "=== 1. Docker 이미지 빌드 (linux/arm64) ==="
# --load 로 buildx 결과를 로컬 daemon 에 즉시 적재 (save 가능하게).
docker buildx build \
    --platform linux/arm64 \
    --load \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    "${SCRIPT_DIR}"

echo ""
echo "=== 2. 이미지 → tar 저장 ==="
docker save -o "${LOCAL_TAR}" "${IMAGE_NAME}:${IMAGE_TAG}"
ls -lh "${LOCAL_TAR}"

echo ""
echo "=== 3. 원격 디렉토리 준비 ==="
ssh "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p ${REMOTE_BASE_DIR}"

echo ""
echo "=== 4. tar + docker-compose.yml 전송 ==="
scp "${LOCAL_TAR}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE_DIR}/${IMAGE_FILE}"
scp "${SCRIPT_DIR}/docker-compose.yml" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE_DIR}/docker-compose.yml"

echo ""
echo "=== 5. 로컬 tar 정리 ==="
rm -f "${LOCAL_TAR}"

echo ""
echo "=== 6. 원격 load + compose up ==="
# heredoc 으로 원격에서 일괄 실행. set -e 로 중간 실패 시 즉시 중단.
ssh "${REMOTE_USER}@${REMOTE_HOST}" bash -s <<REMOTE_SCRIPT
set -euo pipefail
cd "${REMOTE_BASE_DIR}"

echo "  - docker load"
docker load -i "${IMAGE_FILE}"

echo "  - 원격 tar 정리"
rm -f "${IMAGE_FILE}"

echo "  - compose up -d --force-recreate"
docker compose up -d --force-recreate

echo "  - dangling image prune"
docker image prune -f
REMOTE_SCRIPT

echo ""
echo "=== 배포 완료 ==="
echo "확인: ssh ${REMOTE_USER}@${REMOTE_HOST} 'cd ${REMOTE_BASE_DIR} && docker compose logs --tail 20'"
