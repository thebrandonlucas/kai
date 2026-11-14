# Security policy

## Supported versions

Kai is before 1.0, and only the [latest release](https://github.com/thebrandonlucas/kai/releases/latest) gets security fixes. A fix ships in a new release rather than as a patch to an older one, so upgrade to get it.

## Reporting a vulnerability

Please report a vulnerability privately, through GitHub's [private vulnerability reporting](https://github.com/thebrandonlucas/kai/security/advisories/new): on the repository's **Security** tab, choose **Report a vulnerability**. Do not open a public issue, discussion or pull request for it, or mention it on the Discord.

Include what an attacker could do, the Kai version (`kai --version`) and system, and the smallest `Kaifile.roc` or steps that show it. You will get a reply in the advisory. Once a fix is released, the advisory is published with credit to you, unless you would rather not be named.

## Verifying a release

Each release publishes a `SHA256SUMS` file covering its archives, the platform and plugin bundles and `install.sh`. The [install script](install.sh) downloads the release's `SHA256SUMS` and refuses to install an archive whose SHA-256 does not match it. To check a download by hand, run `sha256sum --check --ignore-missing SHA256SUMS` in the directory holding the archive and `SHA256SUMS`.

The checksums come from the same GitHub release as the archive, so they detect a corrupted or swapped download, not a compromised release.

Releases after 0.0.12 also carry signed build provenance: GitHub artifact attestations, made by the release workflow, for every asset it publishes, `SHA256SUMS` included. An attestation ties a file's SHA-256 to the workflow run, commit and repository that built it, so it catches assets replaced outside the repository's GitHub Actions workflows. With the [GitHub CLI](https://cli.github.com/), check a download with:

```sh
gh attestation verify kai-X.Y.Z-x86_64-linux.tar.gz --repo thebrandonlucas/kai \
  --signer-workflow thebrandonlucas/kai/.github/workflows/release.yml
```

It prints the workflow that built the file and fails unless an attestation from this repository's release workflow matches it.
