FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w" -o /out/gateway-service ./cmd/gateway-service

FROM debian:10-slim

WORKDIR /app

COPY --from=builder --chown=10001:10001 /out/gateway-service /app/gateway-service

USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["/app/gateway-service"]
