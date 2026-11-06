# Security policy

## Supported versions

Kai is before 1.0, and only the [latest release](https://github.com/thebrandonlucas/kai/releases/latest) gets security fixes. A fix ships in a new release rather than as a patch to an older one, so upgrade to get it.

## Reporting a vulnerability

Please report a vulnerability privately, through GitHub's [private vulnerability reporting](https://github.com/thebrandonlucas/kai/security/advisories/new): on the repository's **Security** tab, choose **Report a vulnerability**. Do not open a public issue, discussion or pull request for it, or mention it on the Discord.

Include what an attacker could do, the Kai version (`kai --version`) and system, and the smallest `Kaifile.roc` or steps that show it. You will get a reply in the advisory. Once a fix is released, the advisory is published with credit to you, unless you would rather not be named.

## Verifying a release

Each release publishes a `SHA256SUMS` file covering its archives, the platform and plugin bundles and `install.sh`. The [install script](install.sh) downloads the release's `SHA256SUMS` and refuses to install an archive whose SHA-256 does not match it. To check a download by hand, run `sha256sum --check --ignore-missing SHA256SUMS` in the directory holding the archive and `SHA256SUMS`.

The checksums come from the same GitHub release as the archive, so they detect a corrupted or swapped download, not a compromised release.
