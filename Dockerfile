ARG ALPINE_VERSION=3.23

FROM alpine:${ALPINE_VERSION}

ENV HOME=/home/backup \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apk upgrade --no-cache \
    && apk add --no-cache \
      bash \
      ca-certificates \
      coreutils \
      gzip \
      minio-client \
      postgresql-client \
      tar \
      tzdata \
    && addgroup -S -g 65532 backup \
    && adduser -S -D -H -u 65532 -G backup -h /home/backup -s /sbin/nologin backup \
    && mkdir -p /backup /home/backup /usr/local/share/ca-certificates \
    && chown -R backup:backup \
      /backup \
      /home/backup \
      /etc/ssl/certs \
      /usr/local/share/ca-certificates \
    && chown backup:backup /etc/ca-certificates.conf \
    && if command -v mcli >/dev/null 2>&1 && ! command -v mc >/dev/null 2>&1; then ln -s /usr/bin/mcli /usr/local/bin/mc; fi

COPY scripts/toolbox-entrypoint.sh /usr/local/bin/toolbox-entrypoint.sh

RUN chmod 0755 /usr/local/bin/toolbox-entrypoint.sh

USER backup
WORKDIR /backup

CMD ["/usr/local/bin/toolbox-entrypoint.sh"]
