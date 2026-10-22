FROM quay.io/fedora/fedora-silverblue:45

ENV SYSTEMD_OFFLINE=1

# Note on `dnf clean all` placement:
# Each `RUN` is its own image layer. If we install in one RUN and clean in a
# later RUN, the cache is already baked into the lower layer — the cleanup just
# adds a deletion on top, leaving the cache forever in the image's storage.
# To actually shrink the image, the cleanup has to happen in the SAME RUN as
# the install. That's why every `dnf install` below ends with `&& dnf clean all`.

# Tailscale repo
RUN curl -Lo /etc/yum.repos.d/tailscale.repo \
      https://pkgs.tailscale.com/stable/fedora/tailscale.repo

# Packages: scriptlets enabled
RUN dnf install -y \
      tailscale \
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

# Static files: docker group fix-up, forwarding sysctl, iptable_nat module
COPY files/ /

# Enable services at boot. docker.socket (not docker.service) starts the
# daemon on first use instead of every boot.
RUN systemctl enable \
      tailscaled.service \
      docker.socket \
      docker-group-setup.service

# Finalize the OSTree commit
RUN ostree container commit
