FROM quay.io/fedora/fedora-silverblue:45

ENV SYSTEMD_OFFLINE=1

# Note on `dnf clean all` placement:
# Each `RUN` is its own image layer. If we install in one RUN and clean in a
# later RUN, the cache is already baked into the lower layer — the cleanup just
# adds a deletion on top, leaving the cache forever in the image's storage.
# To actually shrink the image, the cleanup has to happen in the SAME RUN as
# the install. That's why every `dnf install` below ends with `&& dnf clean all`.

# Static files: third-party repo files (disabled), docker group fix-up,
# forwarding sysctl, iptable_nat module, Nvidia modprobe options,
# Flatpak list + sync-flatpaks
COPY files/ /

# RPMFusion (needed for Nvidia). The release RPMs ship the repos enabled
# (in /usr/share/dnf5/repos.d/ as of F45, not /etc/yum.repos.d/);
# disable them to match the other third-party repos, and enable them only
# for the Nvidia install below.
RUN dnf install -y \
      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm \
 && sed -i 's/^enabled=1/enabled=0/' /usr/share/dnf5/repos.d/rpmfusion-*.repo \
 && dnf clean all && rm -rf /var/cache/dnf

# Nvidia driver stack: skip scriptlets to avoid the auto-build.
# xorg-x11-drv-nvidia-cuda has to be in this same noscripts install — otherwise
# pulling it in later upgrades akmod-nvidia in a transaction with scriptlets ON,
# and the post scriptlet runs akmodsbuild as root and fails.
RUN dnf install -y --setopt=tsflags=noscripts \
      --enablerepo=rpmfusion-free,rpmfusion-free-updates,rpmfusion-nonfree,rpmfusion-nonfree-updates \
      akmod-nvidia \
      xorg-x11-drv-nvidia-cuda \
 && dnf clean all && rm -rf /var/cache/dnf

# Packages: scriptlets enabled. Third-party repos are enabled for this
# command only; the running system never consults them.
RUN dnf install -y --enablerepo=tailscale-stable --enablerepo=code \
      tailscale \
      code \
      telnet \
      traceroute \
      chromium \
      gnome-tweaks \
      podman-compose \
      distrobox \
      moby-engine \
      docker-compose \
      docker-buildx \
 && dnf clean all && rm -rf /var/cache/dnf

# Install your MOK public key so akmods will sign with the matching private key
COPY cert/mok.der /etc/pki/akmods/certs/public_key.der

# Build and sign the Nvidia kmod against the image's kernel. The private key
# comes in as a build secret and is deleted before the layer is committed.
RUN --mount=type=secret,id=akmods_privkey \
    cp /run/secrets/akmods_privkey /etc/pki/akmods/private/private_key.priv && \
    chown akmods:akmods /etc/pki/akmods/private/private_key.priv && \
    chmod 600 /etc/pki/akmods/private/private_key.priv && \
    KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    dnf install -y kernel-devel-${KVER} gcc make && \
    dnf clean all && rm -rf /var/cache/dnf && \
    if ! akmods --force --kernels "${KVER}"; then \
      echo "=== AKMODS FAILED ===" ; \
      ls -la /var/cache/akmods/nvidia/ ; \
      for f in /var/cache/akmods/nvidia/*.failed.log; do \
        echo "=== $f ===" ; cat "$f" ; \
      done ; \
      exit 1 ; \
    fi && \
    if [ ! -e /usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz ]; then \
      echo "=== KMOD MISSING DESPITE NO ERROR ===" && exit 1 ; \
    fi && \
    rm -f /etc/pki/akmods/private/private_key.priv

# Enable services at boot. docker.socket (not docker.service) starts the
# daemon on first use instead of every boot.
RUN systemctl enable \
      tailscaled.service \
      docker.socket \
      docker-group-setup.service

# Flathub only: don't add Fedora's Flatpak remote on first boot. Existing
# remotes and the preinstall list are applied by `sync-flatpaks`.
RUN systemctl disable flatpak-add-fedora-repos.service

# Finalize the OSTree commit
RUN ostree container commit
