# syntax=docker/dockerfile:1.7

# ====== Stage 1: builder ======
# Go 공식 alpine 이미지는 amd64 + arm64 multi-arch — Pi 에서 자동 arm64.
# 1.25 사용: modernc.org/sqlite 가 Go 1.25+ 요구.
FROM golang:1.25-alpine AS builder

# git 은 일부 go mod download 가 필요로 함. ca-cert 는 빌드 시 go proxy 호출용.
RUN apk add --no-cache git ca-certificates

WORKDIR /src

# 의존 캐시 최적화: go.mod/sum 만 먼저 복사해 mod download 가 layer 캐시.
COPY go.mod go.sum ./
RUN go mod download

# 본 소스 복사 후 빌드. -ldflags='-s -w' 로 심볼/디버그 제거(바이너리 크기↓).
# -trimpath 는 빌드 경로를 binary 에 박지 않아 reproducibility 도움.
COPY . .
RUN go build -ldflags='-s -w' -trimpath -o /out/nunting ./cmd/server

# ====== Stage 2: runtime ======
FROM alpine:3

# ca-certificates: APNs HTTPS 검증용. tzdata: log 타임스탬프 KST 등 옵션.
RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /out/nunting /usr/local/bin/nunting

EXPOSE 8080
CMD ["/usr/local/bin/nunting"]
