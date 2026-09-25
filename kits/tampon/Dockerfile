# syntax=docker/dockerfile:1
# Image de production de tampon (chapitre 13).

# 1. Construction, toujours sur l'architecture de la machine qui construit
FROM --platform=$BUILDPLATFORM golang:1.27 AS construction
ARG TARGETOS TARGETARCH
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY *.go ./
# le cache de compilation de Go survit d'une construction à l'autre
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /tampon .

# 2. Exécution : un binaire statique, des certificats, les fuseaux, un utilisateur
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=construction /tampon /tampon
EXPOSE 8080
ENTRYPOINT ["/tampon"]
