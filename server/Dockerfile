# Build static binaries with the pinned Go version before building the image:
# CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o dist/haoxiguan-server-linux-amd64 ./cmd/haoxiguan-server
# TARGETARCH is supplied automatically by BuildKit, or explicitly via --build-arg.
FROM scratch
ARG TARGETARCH=amd64
COPY --chmod=0555 dist/haoxiguan-server-linux-${TARGETARCH} /haoxiguan-server
COPY --chown=65532:65532 --chmod=0700 deploy/empty-data/ /data/
USER 65532:65532
WORKDIR /data
VOLUME ["/data"]
EXPOSE 8787
ENTRYPOINT ["/haoxiguan-server"]
CMD ["serve", "--db", "/data/haoxiguan.sqlite", "--listen", "0.0.0.0:8787"]
