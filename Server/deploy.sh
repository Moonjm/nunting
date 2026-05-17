#!/usr/bin/env bash
# Mac → 라즈베리파이 배포 (Mac 쪽 실행).
#   1) linux/arm64 이미지 빌드 (Mac buildx cross-compile)
#   2) docker save → tar
#   3) scp tar → 원격 디렉토리
#   4) ssh 로 원격 REMOTE_BASE_DIR/deploy.sh 실행 (load + compose up)
#   5) 로컬 tar 정리
#
# 사전 조건 (Pi 에 한 번만 수동 셋업 — 이 deploy.sh 가 전송하지 않음):
#   - Docker Engine + compose plugin 설치.
#   - REMOTE_BASE_DIR/docker-compose.yml — repo 의 Server/docker-compose.yml 참조.
#   - REMOTE_BASE_DIR/.env — APNS_KEY_ID/TEAM_ID/TOPIC 등 본인 값.
#   - REMOTE_BASE_DIR/secrets/AuthKey_*.p8 — 이미지에 박지 않고 mount 로만.
#   - REMOTE_BASE_DIR/deploy.sh — repo 의 Server/remote-deploy.sh 참조.
#   - Mac 에 Docker Desktop + buildx (docker buildx --version 확인).
#   - ssh key 로그인 (passwordless 권장).
#
# 위 5개 파일이 Pi 에 모두 있는 상태에서만 동작. 셋업 후엔 `./deploy.sh` 한 줄.
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

# 어디서 실패해도 (build/scp/ssh) 로컬 tar 정리 — 대용량 산물 누적 방지.
trap 'rm -f "${LOCAL_TAR}"' EXIT

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
echo "=== 3. tar 전송 ==="
# compose/.env/.p8/deploy.sh 등 다른 파일은 Pi 에 이미 있는 전제 — 변경 시 수동 scp.
scp "${LOCAL_TAR}" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE_DIR}/${IMAGE_FILE}"

echo ""
echo "=== 4. 원격 deploy.sh 실행 ==="
# REMOTE_BASE_DIR 을 single-quote 로 감싸 원격 shell 의 word-splitting 방지
# (경로에 공백 들어가도 cd 가 정상 동작).
ssh "${REMOTE_USER}@${REMOTE_HOST}" "cd '${REMOTE_BASE_DIR}' && bash deploy.sh"
# 로컬 tar 는 위의 trap 이 정리 (EXIT 시).

echo ""
echo "=== 배포 완료 ==="
echo "확인: ssh ${REMOTE_USER}@${REMOTE_HOST} 'cd ${REMOTE_BASE_DIR} && docker compose logs --tail 20'"
