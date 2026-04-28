# syntax=docker/dockerfile:1.7
FROM alpine:3.21

ARG TARGETPLATFORM
ARG TARGETARCH
ARG IG_PUBLISHER_VERSION=2.2.7
ARG SUSHI_VERSION=3.19.0
ARG JEKYLL_VERSION=4.3.4

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    JAVA_HOME=/usr/lib/jvm/default-jvm \
    GEM_HOME=/usr/local/bundle \
    BUNDLE_PATH=/usr/local/bundle \
    PATH=/usr/local/bundle/bin:/usr/lib/jvm/default-jvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    IG_PUBLISHER_JAR=/opt/fhir/publisher.jar \
    WORKSPACE=/workspace \
    OUTPUT=/output \
    SERVER_PORT=8080

# Runtime packages
RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        fontconfig \
        git \
        graphviz \
        nodejs \
        npm \
        openjdk21-jre-headless \
        python3 \
        ruby \
        ruby-etc \
        ruby-bundler \
        shadow \
        su-exec \
        tini \
        ttf-dejavu \
        tzdata \
        unzip

# Build toolchain needed only to compile native Ruby gems; removed afterwards.
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        build-base \
        libffi-dev \
        ruby-dev \
        zlib-dev; \
    gem install --no-document --clear-sources \
        "jekyll:${JEKYLL_VERSION}" \
        rouge \
        kramdown-parser-gfm \
        jekyll-redirect-from \
        jekyll-sitemap \
        webrick; \
    npm install -g --omit=dev "fsh-sushi@${SUSHI_VERSION}"; \
    mkdir -p /opt/fhir; \
    curl -fsSL -o "${IG_PUBLISHER_JAR}" \
        "https://github.com/HL7/fhir-ig-publisher/releases/download/${IG_PUBLISHER_VERSION}/publisher.jar"; \
    apk del .build-deps; \
    rm -rf /root/.gem /root/.npm /tmp/* /var/cache/apk/*

# Default unprivileged identity. The entrypoint remaps this user at runtime
# to match the owner of the mounted workspace (or $PUID/$PGID) and drops
# privileges via su-exec. The container therefore starts as root on purpose.
RUN addgroup -g 1000 ig && \
    adduser -D -u 1000 -G ig -h /home/ig -s /bin/bash ig && \
    mkdir -p /workspace /output /home/ig/.fhir /home/ig/.cache && \
    chown -R ig:ig /workspace /output /home/ig

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
VOLUME ["/workspace", "/output"]
EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["publish"]
