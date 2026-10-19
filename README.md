# Custom Fedora Silverblue Image

A personal Fedora Silverblue OCI image with Tailscale and a few extras baked in, built nightly by GitHub Actions and published to GHCR.

This README is for future-me (or anyone else picking this up cold) so the whole system can be understood and rebuilt without re-deriving everything from scratch.

---

## What this is

Fedora publishes Silverblue as an OCI container image at `quay.io/fedora/fedora-silverblue:<version>`. You can take that image, layer your own customizations on top via a Containerfile, push the result to a registry, and tell `rpm-ostree` on a running Silverblue machine to use *your* image as its OS instead of stock Fedora's. Updates flow through the same mechanism — every nightly rebuild becomes the next available system update.

This repo is exactly that:

- A `Containerfile` that starts from stock Fedora Silverblue and adds: Tailscale, GNOME Tweaks, `podman-compose`, plus a few networking utilities (`telnet`, `traceroute`). It also removes the stock Firefox (used as a Flatpak instead).
- A GitHub Actions workflow that rebuilds the image nightly (and on every push) and publishes to `ghcr.io/<username>/<repo>`.

This image targets an AMD machine (Framework Desktop, Ryzen AI Max / Strix Halo). Graphics are driven by the in-kernel `amdgpu` driver, so there are no out-of-tree kernel modules to build or sign — nothing like the Nvidia/akmods/MOK dance that an Nvidia box would need.

---

## Repo layout

```
.
├── Containerfile                # The image definition
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
2. Builds the image using `buildah` against the Containerfile.
3. Logs into GHCR using the auto-generated `GITHUB_TOKEN`.
4. Pushes the image with two tags: `latest` and the git commit SHA.

The image ends up at `ghcr.io/<username>/<repo>:latest`. The package needs to be set to **public visibility** in GitHub once after the first successful build (Profile → Packages → repo → Package settings → visibility) so that `rpm-ostree` can pull it without authentication.

### Why nightly

Fedora pushes updates to `quay.io/fedora/fedora-silverblue:<version>` continuously. Rebuilding nightly means every morning the image is freshly layered on top of the latest upstream Fedora — security patches, kernel updates, everything flows through automatically. When you `rpm-ostree upgrade` on the machine, you get the new image.

### Containerfile structure

Roughly, in order:

1. `FROM quay.io/fedora/fedora-silverblue:44` — start from stock Fedora.
2. Set `SYSTEMD_OFFLINE=1` so systemd scriptlets don't try to talk to a non-existent init system during build.
3. Drop in the Tailscale repo file.
4. Install userspace bits (`tailscale`, `telnet`, `traceroute`, `gnome-tweaks`, `podman-compose`).
5. Remove unwanted defaults (`firefox`, `firefox-langpacks`, `gnome-browser-connector`).
6. Enable `tailscaled.service`.
7. `ostree container commit` to finalize.

Each step is intentionally a separate `RUN` so that buildah's layer cache works — small Containerfile changes don't force a full rebuild from scratch. The flip side is that `dnf clean all` has to run **inside the same `RUN`** as each install (otherwise the cache lives forever in the lower layer, and cleaning it in a later layer doesn't shrink the image).

---

## Installing this image on a new machine

1. **Install stock Fedora Silverblue 44** from the official ISO. Normal installer, normal partitioning, normal first-boot.

2. **Rebase to this image** (replace `<username>` and `<repo>`):

   ```bash
   sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/<username>/<repo>:latest
   ```

   This downloads the image and stages it as the next deployment.

3. **Reboot** into the new image:

   ```bash
   systemctl reboot
   ```

4. **Set up Tailscale** (one-time per machine):

   ```bash
   sudo tailscale up
   ```

   Follow the auth URL, approve the machine, done.

5. **Set the hostname** (Silverblue installer doesn't prompt for it):

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

2. **Your nightly Actions run pulls it in.** At 06:00 UTC each day, the workflow runs `FROM quay.io/fedora/fedora-silverblue:44`, which fetches whatever the current `:44` is. Your customizations (Tailscale, configs) get layered on top of the new base.

3. **The result is published to GHCR.** Tagged `latest`, replacing the previous build. Old builds are still in GHCR's history (90 days retention by GitHub) if you ever need to dig back.

4. **Your machine sees the new image.** When `rpm-ostree` checks for updates (manually via `rpm-ostree upgrade`, or automatically if you enabled the timer), it notices the digest at `ghcr.io/<username>/<repo>:latest` has changed and stages the new deployment.

5. **You reboot when convenient.** The new image becomes active. The previous deployment is kept as a rollback option.

You don't need to do anything to make this happen. No Containerfile changes, no manual rebuilds, no version bumps. The pipeline runs nightly forever and your machine keeps current automatically.

If a particular nightly build pulls in a broken upstream package, the rollback is one command (`sudo rpm-ostree rollback`) and the next nightly build will probably have the fix.

### Major version upgrades (Fedora 44 → 45 → 46 ...)

Fedora releases a new major version about every six months (typically late April and late October). Each one has its own image tag — `:44`, `:45`, `:46` — and Fedora maintains the previous version for ~13 months after a new one ships, so there's no rush.

The process is intentionally manual. You decide when to upgrade.

**Step 1: Wait (optional).** There's no out-of-tree driver to worry about on this AMD box, so major upgrades are much lower-risk than they'd be on an Nvidia machine. Still, it's reasonable to let a new release settle for a week or two and skim [discussion.fedoraproject.org](https://discussion.fedoraproject.org/) for any Silverblue-specific pain before jumping.

**Step 2: Update the Containerfile.** Change the `FROM` line:

   ```dockerfile
   FROM quay.io/fedora/fedora-silverblue:45
   ```

   That's it for the version itself. Commit and push.

**Step 3: Watch the build.** GitHub Actions kicks off automatically on push. Watch it run. Major version transitions are the most likely time for the build to fail because:
   - Package names sometimes change (a package gets renamed or split in a new release)
   - Repo paths shift
   - Scriptlets in newer systemd or other base packages may behave differently

   If the build fails, debug it the same way as any other failure. Look at the raw log, identify what's missing or broken, fix the Containerfile, push again.

**Step 4: Once the build is green, upgrade the machine.** With a successful new image at `ghcr.io/<username>/<repo>:latest`:

   ```bash
   sudo rpm-ostree upgrade
   sudo systemctl reboot
   ```

   `rpm-ostree` will pull the new image, stage it, and on reboot you're on the new Fedora major version.

**Step 5: Verify.** After reboot:

   ```bash
   cat /etc/os-release | grep VERSION_ID    # Should show 45
   ```

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
- You may want to upgrade specific machines on different schedules.

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

- **"Packages not found: <name>"** — a package may have been renamed/split in a new Fedora release, or the repo isn't available yet. Either wait, drop the package, or pin to a previous Fedora version.
- **Transaction failed during systemd %triggerin** — likely missing the `SYSTEMD_OFFLINE=1` env var or the `--cap-add=AUDIT_WRITE` buildah arg in the workflow.

### Need to debug from a non-graphical environment

Press `Ctrl+Alt+F3` to switch to a TTY. Log in with your normal user. From there you can run all the diagnostic commands without depending on the desktop. `Ctrl+Alt+F1` (or F2) returns to the graphical session.

---

## Useful references

- Fedora's bootc/ostree-native-container change proposal: https://fedoraproject.org/wiki/Changes/OstreeNativeContainerStable
- bootc documentation: https://bootc-dev.github.io/bootc/
- BlueBuild (a higher-level tool that wraps this whole pattern, in case you outgrow the bare Containerfile approach): https://blue-build.org/
