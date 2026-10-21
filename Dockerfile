# syntax=docker/dockerfile:1

# PHP is compiled from the php.net release tarball rather than taken from the
# official php image, so a release can ship as soon as php.net publishes it.
# To bump: set PHP_VERSION and PHP_SHA256 (the tar.xz "sha256" from
# https://www.php.net/releases/?json&version=X.Y.Z).
ARG PHP_VERSION=8.5.12
ARG PHP_SHA256=08bc2eba2a588654ade1357174aa646b761556c862dda0678345ee29ed481209

##------------------------------------------------------------------------------
# Build stages
##------------------------------------------------------------------------------

FROM debian:trixie-slim AS build-debian
ENV DEBIAN_FRONTEND="noninteractive"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<-EOF
    set -eux
    rm -f /etc/apt/apt.conf.d/docker-clean
    apt-get update
    apt-get install --yes --quiet --no-install-recommends ca-certificates curl
EOF

# Downloads the release tarball and refuses it unless both the pinned SHA-256
# matches and the detached signature was made by a PHP 8.5 release manager
# (fingerprints from https://www.php.net/gpg-keys.php).
FROM build-debian AS php-source
ARG PHP_VERSION
ARG PHP_SHA256
ARG GPG_KEYS="1198C0117593497A5EC5C199286AF1F9897469DC 49D9AF6BC72A80D6691719C8AA23F5BE9C7097D4 D95C03BC702BE9515344AE3374E44BC9067701A5"
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<-EOF
    set -eux
    apt-get update
    apt-get install --yes --quiet --no-install-recommends dirmngr gnupg xz-utils
EOF
WORKDIR /usr/src
RUN <<-EOF
    set -eux
    curl -fsSL -o php.tar.xz "https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz"
    curl -fsSL -o php.tar.xz.asc "https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz.asc"
    echo "${PHP_SHA256} *php.tar.xz" | sha256sum -c -

    export GNUPGHOME="$(mktemp -d)"
    for key in $GPG_KEYS; do
        gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key" \
            || curl -fsSL https://www.php.net/distributions/php-keyring.gpg | gpg --batch --import
    done
    gpg --batch --status-fd 1 --verify php.tar.xz.asc php.tar.xz > /tmp/gpg-status
    signer="$(awk '$2 == "VALIDSIG" { print $NF }' /tmp/gpg-status)"
    [[ " $GPG_KEYS " == *" $signer "* ]] || { echo "unexpected signer: ${signer:-none}" >&2; exit 1; }

    mkdir php
    tar -xJf php.tar.xz -C php --strip-components=1
    rm -rf "$GNUPGHOME" php.tar.xz php.tar.xz.asc
EOF

# Same configure flags as the official php:*-apache image, so the extension
# set is unchanged; sodium is built in rather than shared.
FROM build-debian AS php-build
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<-EOF
    set -eux
    apt-get update
    apt-get install --yes --quiet --no-install-recommends \
        apache2 \
        apache2-dev \
        autoconf \
        bison \
        dpkg-dev \
        file \
        g++ \
        gcc \
        libargon2-dev \
        libc-dev \
        libcurl4-openssl-dev \
        libonig-dev \
        libreadline-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        make \
        pkg-config \
        re2c \
        zlib1g-dev
    a2dismod mpm_event
    a2enmod mpm_prefork
EOF
COPY --link --from=php-source /usr/src/php /usr/src/php
WORKDIR /usr/src/php
RUN <<-EOF
    set -eux
    export \
        CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64" \
        CPPFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64" \
        LDFLAGS="-Wl,-O1 -pie" \
        PHP_UNAME="Linux - Docker"
    ./configure \
        --build="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
        --sysconfdir=/usr/local/etc \
        --with-config-file-path=/usr/local/etc/php \
        --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
        --enable-option-checking=fatal \
        --with-mhash \
        --with-pic \
        --enable-mbstring \
        --enable-mysqlnd \
        --with-password-argon2 \
        --with-sodium \
        --with-pdo-sqlite=/usr \
        --with-sqlite3=/usr \
        --with-curl \
        --with-iconv \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --disable-phpdbg \
        --with-libdir="lib/$(dpkg-architecture --query DEB_BUILD_MULTIARCH)" \
        --disable-cgi \
        --with-apxs2
    make -j"$(nproc)"
    find . -type f -name '*.a' -delete
    make install
    mkdir -p /usr/local/etc/php/conf.d
    cp php.ini-development php.ini-production /usr/local/etc/php/

    # Record the Debian packages that provide the shared libraries PHP links
    # against, so the runtime stages install exactly those.
    find /usr/local/bin /usr/lib/apache2/modules/libphp.so -type f -executable \
        -exec ldd '{}' ';' 2>/dev/null \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) next; gsub("^/(usr/)?", "", so); print "*" so }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | awk -F: '/^diversion / { next } { print $1 }' \
        | grep -v '^apache2' \
        | sort -u > /usr/local/etc/php/runtime-packages
    cat /usr/local/etc/php/runtime-packages
EOF

##------------------------------------------------------------------------------
# Runtime stages
##------------------------------------------------------------------------------

# PHP CLI, used by CI for lint, PHPStan and the unit tests.
FROM debian:trixie-slim AS cli
ENV DEBIAN_FRONTEND="noninteractive"
COPY --link --from=php-build /usr/local /usr/local
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<-EOF
    set -eux
    rm -f /etc/apt/apt.conf.d/docker-clean
    apt-get update
    apt-get upgrade --yes --quiet
    xargs -a /usr/local/etc/php/runtime-packages \
        apt-get install --yes --quiet --no-install-recommends ca-certificates
    php -v
    php -m
EOF
CMD ["php", "-a"]

# The console itself: Apache with mod_php. Kept last so a plain
# `docker build .` produces it.
FROM cli AS apache
ENV APACHE_DOCROOT="/var/www"
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked <<-EOF
    set -eux
    apt-get update
    apt-get install --yes --quiet --no-install-recommends apache2
    a2dismod mpm_event
    a2enmod mpm_prefork rewrite
    # envvars reads variables that may be unset.
    set +u
    . /etc/apache2/envvars
    set -u
    for dir in "$APACHE_LOCK_DIR" "$APACHE_RUN_DIR" "$APACHE_LOG_DIR"; do
        rm -rf "$dir"
        mkdir -p "$dir"
        chown www-data:www-data "$dir"
        chmod 1777 "$dir"
    done
    ln -sfT /dev/stderr /var/log/apache2/error.log
    ln -sfT /dev/stdout /var/log/apache2/access.log
    ln -sfT /dev/stdout /var/log/apache2/other_vhosts_access.log
    sed -i 's/Listen 80/Listen 8080/g' /etc/apache2/ports.conf
EOF
COPY --link --from=php-build /usr/lib/apache2/modules/libphp.so /usr/lib/apache2/modules/libphp.so
RUN echo 'LoadModule php_module /usr/lib/apache2/modules/libphp.so' > /etc/apache2/mods-available/php.load
COPY docker/apache-php.conf /etc/apache2/conf-available/docker-php.conf
RUN a2enmod php && a2enconf docker-php && apache2ctl -M 2>/dev/null | grep -q php_module

# Add custom default apache virtual host with combined error and access logging to stdout
COPY docker/apache_vhost /etc/apache2/sites-available/000-default.conf
COPY docker/php.ini /usr/local/etc/php
COPY --chmod=755 docker/apache2-foreground /usr/local/bin/apache2-foreground

WORKDIR "${APACHE_DOCROOT}"
COPY . ./

# Ensure Apache runtime directories and docroot are owned by www-data
RUN chown -R www-data:www-data /var/run/apache2 /var/lock/apache2 /var/log/apache2 "${APACHE_DOCROOT}"

USER www-data
EXPOSE 8080
STOPSIGNAL SIGWINCH
CMD ["apache2-foreground"]
