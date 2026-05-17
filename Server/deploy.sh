#!/usr/bin/env bash
# Mac → 라즈베리파이 배포 (Mac 쪽 실행).
#   1) linux/arm64 이미지 빌드 (Mac buildx cross-compile)
#   2) docker save → tar
#   3) scp tar + remote-deploy.sh → 원격 디렉토리
#   4) ssh 로 원격 deploy.sh 실행 (load + compose up)
#   5) 로컬 tar 정리
#
# 사전 조건 (Pi 에 한 번만 수동 셋업):
#   - Docker Engine + compose plugin 설치.
#   - REMOTE_BASE_DIR 에 docker-compose.yml 배치 (compose 변경 시 수동 scp).
#   - REMOTE_BASE_DIR/.env 작성 (APNS_KEY_ID, TEAM_ID, TOPIC 등 본인 값).
#   - REMOTE_BASE_DIR/secrets/AuthKey_*.p8 scp (이미지에 박지 않고 mount 로만).
#   - Mac 에 Docker Desktop + buildx (docker buildx --version 확인).
#   - ssh key 로그인 (passwordless 권장).
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
IMAGE_TAG="latest"
IMAGE_FILE="${IMAGE_NAME}.tar"
LOCAL_TAR="${SCRIPT_DIR}/${IMAGE_FILE}"

echo ""
echo "=== 1. Docker 이미지 빌드 (linux/arm64) ==="
# --load 로 buildx 결과를 로컬 daemon 에 적재 (save 가능하게).
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
echo "=== 4. tar + remote deploy 스크립트 전송 ==="
# compose/.env/.p8 은 Pi 에 이미 있는 전제 — 매 배포 전송 안 함.
# compose 변경 시 별도 `scp docker-compose.yml ...` 로 수동 갱신.
scp "${LOCAL_TAR}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE_DIR}/${IMAGE_FILE}"
# remote-deploy.sh 를 원격에선 deploy.sh 로 명명 — "해당 경로의 deploy.sh 실행" 패턴.
scp "${SCRIPT_DIR}/remote-deploy.sh" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE_DIR}/deploy.sh"

echo ""
echo "=== 5. 로컬 tar 정리 ==="
rm -f "${LOCAL_TAR}"

echo ""
echo "=== 6. 원격 deploy.sh 실행 ==="
ssh "${REMOTE_USER}@${REMOTE_HOST}" "cd ${REMOTE_BASE_DIR} && bash deploy.sh"

echo ""
echo "=== 배포 완료 ==="
echo "확인: ssh ${REMOTE_USER}@${REMOTE_HOST} 'cd ${REMOTE_BASE_DIR} && docker compose logs --tail 20'"
