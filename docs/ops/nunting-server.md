# NuntingServer 라즈베리파이 운영 가이드

`Server/` 의 Go HTTP 서버를 라즈베리파이 위에서 Docker 로 상시 가동하기 위한 절차 노트. iOS 앱 푸시(키워드 매칭 알림) 의 백엔드.

> 1인 도구 가정. 공개 배포 / 멀티 사용자 / HA 시나리오는 다루지 않는다.

---

## 1. 사전 준비

- 라즈베리파이 4/5 권장 (aarch64 / arm64).
- OS: Ubuntu Server 22.04 LTS (64-bit) 또는 Raspberry Pi OS Lite 64-bit.
- Docker Engine + compose plugin:
  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER
  # 새 셸로 재로그인
  docker compose version  # v2.x 출력 확인
  ```
- APNs 키(`.p8`) — Apple Developer Portal → Keys 에서 발급. Push Notifications 서비스 활성화 필요.

## 2. 초기 setup

```bash
# repo clone (<repo-url> 은 본인 origin URL — 확인: 기존 clone 에서 `git remote get-url origin`)
git clone <repo-url> nunting
cd nunting/Server

# APNs .p8 파일을 라즈베리파이의 secrets/ 디렉토리로 복사 (호스트/경로는 본인 환경).
# 주의: Ubuntu Server 사용 시 Pi 에서 `sudo apt install avahi-daemon` 필요(mDNS).
# Raspberry Pi OS 는 기본 포함.

# .env 작성
cp .env.example .env
nano .env  # APNS_KEY_PATH / APNS_KEY_ID / APNS_TEAM_ID / APNS_TOPIC 채우기

# 빌드 + 기동
docker compose up -d --build
```

**Go 빌드는 30초~1분** (Swift 의 30~60분 대비 60배 빠름).

기동 확인:
```bash
curl http://localhost:${NUNTING_HOST_PORT:-8080}/health
# → ok
docker compose logs -f
# JSON 로그: {"level":"INFO","msg":"http_serving","addr":"0.0.0.0:8080",...}
```

## 3. 업데이트

두 가지 방식 — 본인 환경에 맞춰 선택:

**A) Mac 에서 빌드 → Pi 로 이미지 푸시 (권장, 빠름)**

Mac 쪽 setup (한 번만):
```bash
cd nunting/Server
cp .deploy.env.example .deploy.env
nano .deploy.env  # REMOTE_USER / REMOTE_HOST / REMOTE_BASE_DIR 채우기
```

이후 매 배포:
```bash
cd nunting/Server
./deploy.sh
```

내부 동작: linux/arm64 이미지 빌드(Mac buildx) → tar 저장 → tar 만 scp → ssh 로 원격 deploy.sh 실행 (docker load + compose up -d --force-recreate + image prune). compose/.env/.p8 는 Pi 에 1회 셋업 후 변경 시 수동 갱신. **30초~2분** 끝.

**B) Pi 에서 직접 git pull + rebuild (Mac 없이 SSH 만으로 끝낼 때)**
```bash
cd ~/nunting
git pull
cd Server
docker compose up -d --build --pull always
```

`--pull always` 는 base image(golang:1.25-alpine, alpine:3) patch 갱신을 강제. 한 달 이상 갭이면 권장, 같은 날 재빌드는 생략 가능.

## 4. 로그 확인

```bash
docker compose logs -f          # follow
docker compose logs --tail 200  # 최근 200줄
docker logs nunting-server      # container_name 으로
```

기본 json-file 드라이버 사용 (rotation 없음). SSD 기준으로 무제한 누적도 실용상 문제 없지만, 신경 쓰이면 `docker-compose.yml` 의 service 아래에 `logging: { driver: json-file, options: { max-size: 10m, max-file: 5 } }` 추가하면 50MB 상한 자동 순환.

주요 JSON 로그 키:
- `msg=http_serving` — 기동 직후, addr/db_path/poll_sec 확인.
- `msg=apns_stub_mode` — APNs env 누락. 실제 푸시 안 감.
- `msg=poller_first_tick` — sentinel 잡힘 (재시작 직후 정상).
- `msg=poller_tick_done` — new_posts/apns_sent 카운트.
- `msg=poller_apns_error` — 푸시 실패. err 필드 확인.
- `msg=apns_410_self_heal` — 만료 토큰 자동 정리(정상 동작).

## 5. 외부 노출 (도메인 연결)

이 PR 의 스코프 밖. 본인 환경에 따라:

- **라우터 포트포워딩**: 외부 포트 → 라즈베리파이 LAN IP : `${NUNTING_HOST_PORT}`. 평문 HTTP 라 LAN 신뢰 + Cloudflare proxy 와 짝지을 것.
- **Cloudflare proxy (orange cloud)**: DNS A 레코드 → 본인 공인 IP, "Proxied" 토글. SSL/TLS 모드는 "Flexible" 이면 origin 평문 HTTP 그대로 사용 가능.

> iOS 앱의 App Transport Security 가 평문 origin 을 거부하므로 도메인을 거치는 게 사실상 강제 (`Info.plist` 의 `NSAllowsLocalNetworking` 은 `*.local` / link-local 전용 — 일반 LAN IP `192.168.x.x` 미포함).

## 6. iOS 앱 baseURL 교체 시점

도메인 확정 후, Xcode 에서 한 줄:

`nunting/Services/AlertSubscriptionService.swift` 의 `defaultBaseURL` 을:
```swift
static let defaultBaseURL = URL(string: "https://your-domain.com")!
```
로 변경 → 앱 archive → 사이드로드/TestFlight 재설치 (Keychain UUID 는 유지되므로 서버 입장에선 같은 사용자).

## 7. 트러블슈팅

**(1) `port is already allocated`**
`NUNTING_HOST_PORT` 가 이미 다른 프로세스 사용 중. `sudo lsof -i :8080` 로 확인 후 .env 에서 다른 포트로 변경 후 `docker compose up -d`.

**(2) 서버가 기동 직후 crash/exit — `.p8` 경로 문제**
- `Server/secrets/` 에 `.p8` 파일이 실제로 존재하는지 (`ls Server/secrets/`).
- `.env` 의 `APNS_KEY_PATH` 가 **컨테이너 내부 경로** (`/run/secrets/AuthKey_XXX.p8`) 인지 — 호스트 경로(`./secrets/...`) 가 아님.

**(3) APNs 403 InvalidProviderToken**
- Apple Developer Portal → Keys → 해당 키의 Push Notifications 서비스 활성화 확인.
- Team ID 는 Membership 페이지 10자 ID.
- 시계 어긋남: Pi 시각이 ±1 시간 이상 벗어나면 JWT 거부. `timedatectl` 로 NTP 확인.

**(4) SQLite 권한 (`unable to open database file`)**
컨테이너는 root(UID 0) 로 동작 — 호스트 `Server/data/` 가 root 가 아닌 user 소유면 컨테이너가 쓰기 실패. `sudo chmod 777 Server/data` (1인 도구라 OK) 또는 `sudo chown -R root:root Server/data`.

**(5) 폴러가 알림 안 보내는데 매칭 글은 있는 듯**
첫 tick 은 의도적으로 sentinel 만 잡고 알림 skip. 다음 tick(3분 후) 부터 신규 글에 알림. `docker compose logs -f | grep poller_` 로 동작 확인.

## 8. SQLite 파일 직접 조회

호스트(라즈베리파이) repo 루트에서 `sqlite3` 패키지 설치 후:
```bash
cd ~/nunting
sudo apt install -y sqlite3
sqlite3 Server/data/state.db
sqlite> .tables
sqlite> SELECT * FROM users;
```
컨테이너 안에는 `sqlite3` CLI 없음. 백업이 필요하면 `cp Server/data/state.db Server/data/state.db.bak`.
