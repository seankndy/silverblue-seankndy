FROM quay.io/fedora/fedora-silverblue:44

# RPMFusion (needed for Nvidia)
RUN rpm-ostree install -y \
      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Tailscale repo
RUN curl -Lo /etc/yum.repos.d/tailscale.repo \
      https://pkgs.tailscale.com/stable/fedora/tailscale.repo

# Install Nvidia, Tailscale, and the kernel headers needed to build the kmod
RUN rpm-ostree install -y \
      tailscale \
      akmod-nvidia \
      xorg-x11-drv-nvidia-cuda

# Install your MOK public key so akmods will sign with the matching private key
COPY cert/mok.der /etc/pki/akmods/certs/public_key.der

# Mount the private key from a build secret, build and sign the Nvidia kmod,
# then delete the private key so it never lands in the final image
RUN --mount=type=secret,id=akmods_privkey \
    cp /run/secrets/akmods_privkey /etc/pki/akmods/private/private_key.priv && \
    chmod 600 /etc/pki/akmods/private/private_key.priv && \
    KVER=$(rpm -q kernel --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}') && \
    rpm-ostree install -y kernel-devel-${KVER} && \
    akmods --force --kernels "${KVER}" && \
    test -e /usr/lib/modules/${KVER}/extra/nvidia/nvidia.ko.xz && \
    rm -f /etc/pki/akmods/private/private_key.priv

# Enable Tailscale at boot
RUN systemctl enable tailscaled.service

# Finalize the OSTree commit
RUN ostree container commit
