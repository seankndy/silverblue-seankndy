FROM quay.io/fedora/fedora-silverblue:45

ENV SYSTEMD_OFFLINE=1

# Note on `dnf clean all` placement:
# Each `RUN` is its own image layer. If we install in one RUN and clean in a
# later RUN, the cache is already baked into the lower layer — the cleanup just
# adds a deletion on top, leaving the cache forever in the image's storage.
# To actually shrink the image, the cleanup has to happen in the SAME RUN as
# the install. That's why every `dnf install` below ends with `&& dnf clean all`.

# Static files: third-party repo files (disabled), docker group fix-up,
# forwarding sysctl, iptable_nat module
COPY files/ /

# Packages: scriptlets enabled. Third-party repos are enabled for this
# command only; the running system never consults them.
RUN dnf install -y --enablerepo=tailscale-stable --enablerepo=code \
      tailscale \
      code \
      telnet \
      traceroute \
      gnome-tweaks \
      podman-compose \
      distrobox \
      moby-engine \
      docker-compose \
      docker-buildx \
 && dnf clean all && rm -rf /var/cache/dnf

# Remove unwanted defaults (gnome-browser-connector is not useful since firefox will be in a flatpak)
RUN dnf remove -y firefox firefox-langpacks gnome-browser-connector

# Enable services at boot. docker.socket (not docker.service) starts the
# daemon on first use instead of every boot.
RUN systemctl enable \
      tailscaled.service \
      docker.socket \
      docker-group-setup.service

# Finalize the OSTree commit
RUN ostree container commit
