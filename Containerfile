FROM quay.io/fedora/fedora-silverblue:44

ENV SYSTEMD_OFFLINE=1

# RPMFusion (needed for Nvidia)
RUN dnf install -y \
      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Tailscale repo
RUN curl -Lo /etc/yum.repos.d/tailscale.repo \
      https://pkgs.tailscale.com/stable/fedora/tailscale.repo

# akmod-nvidia: skip scriptlets to avoid the auto-build
RUN dnf install -y --setopt=tsflags=noscripts akmod-nvidia-open

# Everything else: scriptlets enabled
RUN dnf install -y \
      xorg-x11-drv-nvidia-cuda \
      tailscale

# Blacklist nouveau and set Nvidia module options
RUN cat > /etc/modprobe.d/nvidia.conf <<EOF
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
EOF

# Bake nvidia modules into initramfs, exclude nouveau from initramfs
RUN cat > /etc/dracut.conf.d/nvidia.conf <<EOF
add_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
omit_drivers+=" nouveau "
EOF

# Install your MOK public key so akmods will sign with the matching private key
COPY cert/mok.der /etc/pki/akmods/certs/public_key.der

# Build and sign the Nvidia kmod against this image's kernel
RUN --mount=type=secret,id=akmods_privkey \
    cp /run/secrets/akmods_privkey /etc/pki/akmods/private/private_key.priv && \
    chown akmods:akmods /etc/pki/akmods/private/private_key.priv && \
    chmod 600 /etc/pki/akmods/private/private_key.priv && \
    KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    dnf install -y kernel-devel-${KVER} gcc make && \
    akmods --force --kernels "${KVER}" || true; \
    if [ ! -e /usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz ]; then \
      echo "=== KMOD NOT BUILT — DUMPING DIAGNOSTICS ===" ; \
      ls -la /var/cache/akmods/nvidia/ || true ; \
      for f in /var/cache/akmods/nvidia/*.failed.log; do \
        echo "=== $f ===" ; cat "$f" || true ; \
      done ; \
      exit 1 ; \
    fi && \
    rm -f /etc/pki/akmods/private/private_key.priv

# Enable Tailscale at boot
RUN systemctl enable tailscaled.service

# Clean up dnf cache so it doesn't bloat the image
RUN dnf clean all && rm -rf /var/cache/dnf

# Finalize the OSTree commit
RUN ostree container commit
