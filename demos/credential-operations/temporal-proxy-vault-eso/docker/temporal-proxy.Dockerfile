# Builds Temporal Proxy from a source tree (the build context) at a pinned
# commit. The runtime stage mirrors the upstream image: a static binary on
# scratch, running as an unprivileged user, with system CA roots so the proxy
# can verify Temporal Cloud's server certificate.
FROM golang:1.27.3-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/proxy ./cmd/proxy

FROM alpine:3.24.1 AS base
RUN adduser -D -u 1000 proxy && mkdir -p /rootfs/tmp

FROM scratch
COPY --from=base /etc/passwd /etc/passwd
COPY --from=base /etc/group /etc/group
COPY --from=base /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=base --chmod=1777 /rootfs/tmp /tmp
COPY --from=build /out/proxy /usr/local/bin/proxy
USER 1000
ENTRYPOINT ["proxy"]
CMD ["--help"]
