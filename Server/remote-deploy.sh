#!/usr/bin/env bash
# 라즈베리파이 쪽 실행 — Mac 의 deploy.sh 가 scp 한 tar 를 받아 load + compose up.
# 이 파일은 repo 에 `remote-deploy.sh` 로 저장돼 있고, 배포 시 원격 path 의
# `deploy.sh` 로 scp 됨. 따라서 Pi 에선 `bash deploy.sh` 로 호출.
#
# 가정: 같은 디렉토리에 nunting-server.tar + docker-compose.yml + .env + secrets/ 가 있다.
#
# 사용법 (수동): ssh 후 `cd /home/pi/docker/nunting && bash deploy.sh`
#               보통은 Mac 의 deploy.sh 가 자동 호출.

set -euo pipefail

IMAGE_FILE="nunting-server.tar"

if [ ! -f "${IMAGE_FILE}" ]; then
    echo "ERROR: ${IMAGE_FILE} 가 현재 디렉토리에 없습니다." >&2
    exit 1
fi

echo "  - docker load"
docker load -i "${IMAGE_FILE}"

echo "  - tar 정리"
rm -f "${IMAGE_FILE}"

echo "  - compose up -d --force-recreate"
docker compose up -d --force-recreate

echo "  - dangling image prune"
docker image prune -f

echo "  - 현재 상태"
docker compose ps
