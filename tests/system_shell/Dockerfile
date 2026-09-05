ARG DEBIAN_IMAGE=debian:bookworm-slim
FROM ${DEBIAN_IMAGE}
SHELL ["/bin/bash", "-eu", "-o", "pipefail", "-c"]
RUN printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential autoconf automake libtool pkg-config python3 ca-certificates file bison texinfo \
    gettext libssl-dev libcurl4-openssl-dev libexpat1-dev zlib1g-dev libpcre2-dev libgmp-dev \
    libacl1-dev libattr1-dev dejagnu locales perl diffutils xz-utils
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && mkdir /sources && cd /sources && \
    apt-get source --download-only hello dash gzip coreutils findutils git && \
    for archive in *.orig.tar.*; do \
      case "$archive" in *.asc) continue;; esac; \
      tar -xf "$archive"; \
    done
# Use upstream release build files, not Debian patches requiring distro-specific
# dh_autoreconf preparation. Archive names and hashes remain in the image.
COPY rush /usr/local/bin/rush
COPY fixtures /fixtures
RUN mkdir /results /work /packages && useradd -m tester && \
    for version in 1 2; do \
      mkdir -p /packages/build/DEBIAN; \
      printf 'Package: rush-shell-lifecycle\nVersion: %s\nArchitecture: all\nMaintainer: Rush tests <nobody@example.invalid>\nDescription: isolated maintainer-script lifecycle probe\n' "$version" >/packages/build/DEBIAN/control; \
      for script in preinst postinst prerm postrm; do \
        cp /fixtures/package-maintainer.sh /packages/build/DEBIAN/"$script"; \
        chmod 755 /packages/build/DEBIAN/"$script"; \
      done; \
      dpkg-deb --build /packages/build /packages/lifecycle-"$version".deb; \
    done
