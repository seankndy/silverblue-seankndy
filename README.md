# Custom Fedora Silverblue Image

A personal Fedora Silverblue OCI image with Tailscale and Nvidia drivers baked in, built nightly by GitHub Actions and published to GHCR.

This README is for future-me (or anyone else picking this up cold) so the whole system can be understood and rebuilt without re-deriving everything from scratch.

---

## What this is

Fedora publishes Silverblue as an OCI container image at `quay.io/fedora/fedora-silverblue:<version>`. You can take that image, layer your own customizations on top via a Containerfile, push the result to a registry, and tell `rpm-ostree` on a running Silverblue machine to use *your* image as its OS instead of stock Fedora's. Updates flow through the same mechanism — every nightly rebuild becomes the next available system update.

This repo is exactly that:

- A `Containerfile` that starts from stock Fedora Silverblue and adds: Tailscale, Nvidia drivers (open kernel modules, signed with a personal MOK key), modprobe options needed to make Nvidia + Wayland behave (nouveau itself is blocked via kargs on each machine — see below), GNOME Tweaks, plus a few networking utilities (`telnet`, `traceroute`).
- A GitHub Actions workflow that rebuilds the image nightly (and on every push), signs the Nvidia kmod during the build, and publishes to `ghcr.io/<username>/<repo>`.
- The signing public key (`cert/mok.der`) needed to enroll on each machine that boots this image.

The matching private key (`mok.priv`) is **not** in the repo. It lives in 1Password and is referenced by GitHub Actions via a repository secret.

---

## Repo layout

```
.
├── Containerfile                # The image definition
├── cert/
│   └── mok.der                  # Public half of the MOK signing key (committed, safe)
├── .github/
│   └── workflows/
│       └── build.yml            # Nightly + on-push build pipeline
└── README.md                    # This file
```

---

## How the build works

The GitHub Actions workflow (`.github/workflows/build.yml`) runs on three triggers:

- **Nightly** at 06:00 UTC (cron schedule)
- **On push** to `main`
- **Manually** via the "Run workflow" button in the Actions tab

When it runs, the workflow does this:

1. Checks out the repo onto an Ubuntu runner.
2. Decodes the MOK private key from the `AKMODS_PRIVKEY` secret into a temp file.
3. Builds the image using `buildah` against the Containerfile, mounting the private key as a build-time secret (so it's used during akmods signing but never written into the final image).
4. Logs into GHCR using the auto-generated `GITHUB_TOKEN`.
5. Pushes the image with two tags: `latest` and the git commit SHA.
6. Cleans up the temp key file.

The image ends up at `ghcr.io/<username>/<repo>:latest`. The package needs to be set to **public visibility** in GitHub once after the first successful build (Profile → Packages → repo → Package settings → visibility) so that `rpm-ostree` can pull it without authentication.

### Why nightly

Fedora pushes updates to `quay.io/fedora/fedora-silverblue:<version>` continuously. Rebuilding nightly means every morning the image is freshly layered on top of the latest upstream Fedora — security patches, kernel updates, everything flows through automatically. When you `rpm-ostree upgrade` on the machine, you get the new image.

### Containerfile structure

Roughly, in order:

1. `FROM quay.io/fedora/fedora-silverblue:44` — start from stock Fedora.
2. Set `SYSTEMD_OFFLINE=1` so systemd scriptlets don't try to talk to a non-existent init system during build.
3. Install RPMFusion repo packages (needed for Nvidia).
4. Drop in the Tailscale repo file.
5. Install `akmod-nvidia` with `--setopt=tsflags=noscripts` (this prevents the auto-build scriptlet from running, which would fail in a build container because akmods refuses to run as root).
6. Install other userspace bits (`xorg-x11-drv-nvidia-cuda`, `tailscale`).
7. Write `/usr/lib/modprobe.d/nvidia.conf` with Nvidia module options (`/usr/lib/modprobe.d/` rather than `/etc/modprobe.d/` because `/etc` is per-machine on OSTree). Nouveau is blocked at the karg level on each machine; the modprobe entries here are belt-and-suspenders only.
8. Copy the public MOK key to `/etc/pki/akmods/certs/public_key.der`.
9. Mount the private key as a build secret, chown it to the `akmods` user (otherwise `sign-file` gets permission-denied), then run `akmods --force` to compile and sign the Nvidia kmod against the kernel in the image.
10. Enable `tailscaled.service`.
11. `ostree container commit` to finalize.

Each step is intentionally a separate `RUN` so that buildah's layer cache works — small Containerfile changes don't force a full rebuild from scratch. The flip side is that `dnf clean all` has to run **inside the same `RUN`** as each install (otherwise the cache lives forever in the lower layer, and cleaning it in a later layer doesn't shrink the image).

---

## How MOK signing works

Linux kernels with Secure Boot enabled refuse to load kernel modules unless they're signed by a key the kernel trusts. The Nvidia kernel module is out-of-tree (not shipped by Fedora), so it needs to be signed by *you* with a key that *you* enroll into the system's trust list.

The trust list for user-added keys is called **MOK** (Machine Owner Key). It's stored in NVRAM on the motherboard, separate from your disk, and survives OS reinstalls. Shim (the bootloader) reads it at boot and passes it to the kernel as additional trusted signers beyond the firmware-level keys.

### Generating the key (one-time, already done)

```bash
openssl req -new -x509 -newkey rsa:2048 \
  -keyout mok.priv -outform DER -out mok.der \
  -nodes -days 36500 \
  -subj "/CN=My Silverblue Signing Key/"
```

This produced two files:

- `mok.priv` — private key, kept secret. **Stored in 1Password.** Also stored in GitHub as the `AKMODS_PRIVKEY` repository secret (base64-encoded).
- `mok.der` — public key, committed to the repo at `cert/mok.der`.

### How signing happens during build

The Containerfile mounts the private key from the GitHub secret into the build at `/run/secrets/akmods_privkey`, copies it to `/etc/pki/akmods/private/private_key.priv`, chowns it to the `akmods` user, and runs `akmods --force`. Akmods compiles the Nvidia kernel module, sees the signing keys in `/etc/pki/akmods/`, and signs the result. Then the private key is deleted from the image so it doesn't end up baked into the published artifact.

### How enrollment happens on a machine (one-time per machine)

After installing Silverblue and rebasing to this image (see below), but before the first boot can use Nvidia properly, the public key has to be enrolled into MOK on that specific machine:

```bash
sudo mokutil --import /path/to/mok.der
```

It prompts for a one-time password — make something up, you only need it for the next 60 seconds. Reboot. At boot, the blue **MOK Manager** screen appears (looks like a retro BIOS menu). Choose:

1. **Enroll MOK**
2. **View key 0** (optional, just to verify it's the right key — should show `CN=My Silverblue Signing Key`)
3. **Continue**
4. **Yes**
5. Enter the one-time password
6. **Reboot**

After that, the kernel trusts modules signed by this key forever on this machine. Any future image rebuilds with new Nvidia kmods will continue to work without re-enrollment, because they're all signed with the same key.

### Recovering / rotating the key

If the private key is lost, the public key in MOK on existing machines is now useless and a new key has to be generated, the public half re-enrolled on every machine, and the private half put back into 1Password and GitHub secrets. So: don't lose `mok.priv`. It's in 1Password under "Silverblue MOK signing key".

---

## Installing this image on a new machine

1. **Install stock Fedora Silverblue 44** from the official ISO. Normal installer, normal partitioning, normal first-boot.

2. **Rebase to this image** (replace `<username>` and `<repo>`):

   ```bash
   sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/<username>/<repo>:latest
   ```

   This downloads the image and stages it as the next deployment.

3. **Enroll the MOK key**. Get `mok.der` onto the machine (USB stick, scp, downloaded from this repo — the public key is fine to fetch over plain HTTP):

   ```bash
   sudo mokutil --import mok.der
   ```

   Set a one-time password when prompted, then reboot. Complete the MOK Manager dance (see "How MOK signing works" above).

4. **Disable nouveau in kargs**. So that nvidia is the driver that wins.

   ```bash
   sudo rpm-ostree kargs \
     --append=rd.driver.blacklist=nouveau \
     --append=modprobe.blacklist=nouveau \
     --append=nvidia-drm.modeset=1
   ```

5. **Reboot** into the new image:

   ```bash
   systemctl reboot
   ```

6. **Verify everything works** after the second reboot:

   ```bash
   mokutil --sb-state                              # SecureBoot enabled
   mokutil --list-enrolled | grep -i 'CN='         # Your key is listed
   lsmod | grep nvidia                             # Modules loaded
   nvidia-smi                                      # GPU shows up
   modinfo nvidia | grep -i license                # Dual MIT/GPL = open driver
   ```

7. **Set up Tailscale** (one-time per machine):

   ```bash
   sudo tailscale up
   ```

   Follow the auth URL, approve the machine, done.

8. **Set the hostname** (Silverblue installer doesn't prompt for it):

   ```bash
   sudo hostnamectl set-hostname <name>
   ```

After this the machine is fully set up. Future updates flow automatically — `rpm-ostree` checks for new image versions and stages them; reboot to apply.

---

## Day-to-day operations

### Apply image updates

```bash
sudo rpm-ostree upgrade
sudo systemctl reboot
```

Or set up automatic staging (already configured in the image):

```bash
sudo systemctl enable --now rpm-ostreed-automatic.timer
```

This pulls new versions in the background; you reboot when convenient.

### Roll back to the previous version

If a new image is broken:

```bash
sudo rpm-ostree rollback
sudo systemctl reboot
```

`rpm-ostree status` shows both the current and previous deployments. The previous one is always retained until the next upgrade succeeds.

### Roll back to stock Fedora Silverblue

If something goes catastrophically wrong with the custom image:

```bash
sudo rpm-ostree rebase fedora:fedora/44/x86_64/silverblue
sudo systemctl reboot
```

That puts you back on stock Fedora's published ostree branch. You can rebase back to the custom image any time.

---

## Updates and version upgrades

There are two kinds of updates: continuous (within a Fedora release) and major (jumping to a new Fedora release). They work differently.

### Continuous updates within a Fedora release (the common case)

Fedora pushes updates to `quay.io/fedora/fedora-silverblue:44` constantly — kernel patches, security fixes, package updates, the works. The `:44` tag is a moving target that always points at the latest F44 build.

The flow:

1. **Fedora updates the base image.** Every few days/weeks, `quay.io/fedora/fedora-silverblue:44` gets a new build with whatever upstream has accumulated.

2. **Your nightly Actions run pulls it in.** At 06:00 UTC each day, the workflow runs `FROM quay.io/fedora/fedora-silverblue:44`, which fetches whatever the current `:44` is. Your customizations (Tailscale, Nvidia, configs) get layered on top of the new base.

3. **The result is published to GHCR.** Tagged `latest`, replacing the previous build. Old builds are still in GHCR's history (90 days retention by GitHub) if you ever need to dig back.

4. **Your machine sees the new image.** When `rpm-ostree` checks for updates (manually via `rpm-ostree upgrade`, or automatically if you enabled the timer), it notices the digest at `ghcr.io/<username>/<repo>:latest` has changed and stages the new deployment.

5. **You reboot when convenient.** The new image becomes active. The previous deployment is kept as a rollback option.

You don't need to do anything to make this happen. No Containerfile changes, no manual rebuilds, no version bumps. The pipeline runs nightly forever and your machine keeps current automatically.

If a particular nightly build pulls in a broken upstream package, the rollback is one command (`sudo rpm-ostree rollback`) and the next nightly build will probably have the fix.

### Major version upgrades (Fedora 44 → 45 → 46 ...)

Fedora releases a new major version about every six months (typically late April and late October). Each one has its own image tag — `:44`, `:45`, `:46` — and Fedora maintains the previous version for ~13 months after a new one ships, so there's no rush.

The process is intentionally manual. You decide when to upgrade.

**Step 1: Wait.** Don't rush a major upgrade in the first 2–4 weeks after release. Specifically for this image, the Nvidia stack needs time to settle:
   - RPMFusion has to rebuild `akmod-nvidia` against the new Fedora's kernel
   - Sometimes the proprietary Nvidia driver itself needs an update to support the new kernel API
   - The first few weeks after a Fedora release are when these mismatches show up

   A reasonable rule: wait until the new release is at least a month old, has a `.1` point release, and Nvidia + your hardware combo has been working for other people. Check [discussion.fedoraproject.org](https://discussion.fedoraproject.org/) for current pain.

**Step 2: Update the Containerfile.** Change the `FROM` line:

   ```dockerfile
   FROM quay.io/fedora/fedora-silverblue:45
   ```

   That's it for the version itself. Commit and push.

**Step 3: Watch the build.** GitHub Actions kicks off automatically on push. Watch it run. Major version transitions are the most likely time for the build to fail because:
   - Package names sometimes change (a package gets renamed or split in a new release)
   - Repo paths shift
   - Scriptlets in newer systemd or other base packages may behave differently
   - RPMFusion may not have all packages built for the new release yet

   If the build fails, debug it the same way as any other failure. Look at the raw log, identify what's missing or broken, fix the Containerfile, push again. The troubleshooting section above covers the common categories.

**Step 4: Once the build is green, upgrade the machine.** With a successful new image at `ghcr.io/<username>/<repo>:latest`:

   ```bash
   sudo rpm-ostree upgrade
   sudo systemctl reboot
   ```

   `rpm-ostree` will pull the new image, stage it, and on reboot you're on the new Fedora major version.

**Step 5: Verify.** After reboot:

   ```bash
   cat /etc/os-release | grep VERSION_ID    # Should show 45
   nvidia-smi                                # Nvidia still works
   lsmod | grep nvidia                       # Modules loaded
   ```

   The MOK enrollment carries over — you don't need to re-enroll the key on a major version upgrade. It's stored in NVRAM independent of any OS state.

**Step 6: If something breaks, roll back.** Same as any update:

   ```bash
   sudo rpm-ostree rollback
   sudo systemctl reboot
   ```

   This puts you back on the previous deployment, which is the F44 image. Then revert the Containerfile change in git, push, and you're back to a working state while you sort out what went wrong with F45.

### Why this isn't automatic

It would be technically easy to make the Containerfile track the latest Fedora release (e.g., `:latest` instead of `:44`), but that's a bad idea for a couple of reasons:

- Major version transitions can break things in surprising ways. You want them to happen on your terms, not at 06:00 UTC on a random Tuesday.
- The image tag pinning is your version anchor. If something breaks after a major upgrade, you can revert the Containerfile commit and rebuild against the old version cleanly.
- You may want to upgrade specific machines on different schedules (e.g., personal laptop early, work desktop after things stabilize).

The one-line Containerfile change is the right amount of friction.

### What about minor Fedora releases?

Fedora doesn't really do "minor" releases the way Ubuntu does (e.g., 24.04.1, 24.04.2). Updates within a major version are continuous, not packaged into discrete point releases. You might see version strings like `Fedora 44.20260425.0` (in `hostnamectl` output) — that's a build date, not a minor version. It changes constantly and you don't manage it.

So in practice you only have two upgrade modes: the continuous flow that happens automatically, and the deliberate major-version bump that requires a Containerfile change.

---

## Modifying the image

The whole point: this is your OS, defined declaratively. To add or change anything:

1. Edit `Containerfile`.
2. Commit and push to `main`.
3. The Actions workflow rebuilds and publishes within a few minutes.
4. On the machine: `sudo rpm-ostree upgrade && sudo systemctl reboot`.

Common modifications:

- **Add a package**: append to one of the `dnf install` lines.
- **Change a system config file**: add a `RUN` step that writes the file.
- **Enable a systemd service**: `RUN systemctl enable <service>.service`.
- **Add a kernel arg permanently**: handle this with `rpm-ostree kargs --append=...` on each machine, *or* embed in the Containerfile via `/usr/lib/bootc/kargs.d/` (newer bootc-style approach).

---

## Troubleshooting

### Build fails in GitHub Actions

Check the failed workflow run, click into the `build` job, expand the failed step. If the log is truncated in the browser, click the gear icon (top-right of log panel) → **View raw logs** for the full output.

Common failures and what they mean:

- **"Packages not found: <name>"** — RPMFusion sometimes lags behind a new Fedora release. Either wait, drop the package, or pin to a previous Fedora version.
- **"akmods scriptlet failed: not to be used as root"** — the `--setopt=tsflags=noscripts` flag isn't on the akmod-nvidia install line.
- **akmods signing: "Permission denied"** — the private key isn't chowned to the `akmods` user before signing.
- **Transaction failed during systemd %triggerin** — likely missing the `SYSTEMD_OFFLINE=1` env var or the `--cap-add=AUDIT_WRITE` buildah arg in the workflow.

### Machine boots but Nvidia doesn't load

Check in order:

```bash
lsmod | grep nouveau                     # Should be empty (blacklisted)
lsmod | grep nvidia                      # Should show modules
sudo dmesg | grep -iE 'nvidia|nouveau'   # The truth
mokutil --list-enrolled | grep CN        # Your key is enrolled
```

If nouveau is loaded, the kargs didn't take effect. Check `rpm-ostree kargs` for `rd.driver.blacklist=nouveau` and `modprobe.blacklist=nouveau`, and verify the modprobe options shipped in the image (`cat /usr/lib/modprobe.d/nvidia.conf`).

If `dmesg` shows "Loading of unsigned module is rejected" or signature errors, the MOK enrollment didn't complete or the kmod was signed with a different key than the one enrolled.

### Flatpaks don't open but Firefox works

Almost always Nvidia driver state — Flatpaks try to set up GPU acceleration and hang/fail when the driver isn't loaded properly. Same diagnostic as above. The fix is whatever fixes Nvidia.

### Need to debug from a non-graphical environment

Press `Ctrl+Alt+F3` to switch to a TTY. Log in with your normal user. From there you can run all the diagnostic commands without depending on the desktop. `Ctrl+Alt+F1` (or F2) returns to the graphical session.

---

## Useful references

- Fedora's bootc/ostree-native-container change proposal: https://fedoraproject.org/wiki/Changes/OstreeNativeContainerStable
- bootc documentation: https://bootc-dev.github.io/bootc/
- uBlue's akmods repo (good reference for how the pros do Nvidia): https://github.com/ublue-os/akmods
- BlueBuild (a higher-level tool that wraps this whole pattern, in case you outgrow the bare Containerfile approach): https://blue-build.org/
