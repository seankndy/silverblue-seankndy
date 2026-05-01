FROM quay.io/fedora/fedora-silverblue:44

ENV SYSTEMD_OFFLINE=1

# Note on `dnf clean all` placement:
# Each `RUN` is its own image layer. If we install in one RUN and clean in a
# later RUN, the cache is already baked into the lower layer — the cleanup just
# adds a deletion on top, leaving the cache forever in the image's storage.
# To actually shrink the image, the cleanup has to happen in the SAME RUN as
# the install. That's why every `dnf install` below ends with `&& dnf clean all`.

# RPMFusion (needed for Nvidia)
RUN dnf install -y \
      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm \
 && dnf clean all && rm -rf /var/cache/dnf

# Tailscale repo
RUN curl -Lo /etc/yum.repos.d/tailscale.repo \
      https://pkgs.tailscale.com/stable/fedora/tailscale.repo

# akmod-nvidia: skip scriptlets to avoid the auto-build
RUN dnf install -y --setopt=tsflags=noscripts akmod-nvidia \
 && dnf clean all && rm -rf /var/cache/dnf

# Everything else: scriptlets enabled
RUN dnf install -y \
      xorg-x11-drv-nvidia-cuda \
      tailscale \
      telnet \
      traceroute \
      gnome-tweaks \
 && dnf clean all && rm -rf /var/cache/dnf

# Remove unwanted defaults (gnome-browser-connector is not useful since firefox will be in a flatpak)
RUN dnf remove -y firefox firefox-langpacks gnome-browser-connector

# Nvidia module options — written to /usr/lib/modprobe.d/ (not /etc/modprobe.d/)
# because /etc is per-machine on OSTree. Nouveau is blocked via kargs (see README),
# so the nouveau entries here are belt-and-suspenders only.
RUN printf '%s\n' \
    'blacklist nouveau' \
    'options nouveau modeset=0' \
    'options nvidia-drm modeset=1 fbdev=1' \
    'options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp' \
    > /usr/lib/modprobe.d/nvidia.conf

# Install your MOK public key so akmods will sign with the matching private key
COPY cert/mok.der /etc/pki/akmods/certs/public_key.der

# Build and sign the Nvidia kmod
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

# Enable Tailscale at boot
RUN systemctl enable tailscaled.service

# Finalize the OSTree commit
RUN ostree container commit
