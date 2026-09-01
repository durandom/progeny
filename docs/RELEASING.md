# Releasing

Releases are hosted entirely on GitHub. orrery consumes them as a pinned
`.tar.gz` (archive sha256 + binary sha256), the same shape as token-burn.

## Create a Release

The workflow file must already be on the tagged commit. Then:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The `release` workflow runs on `macos-15` (Apple Silicon) and publishes:

- `progenyd_<version>_darwin_arm64.tar.gz`
- `checksums.txt`

Each archive contains:

- `progenyd_<version>_darwin_arm64/progenyd`
- `progenyd_<version>_darwin_arm64/README.md`
- `progenyd_<version>_darwin_arm64/LICENSE`

There is no Linux build and no Intel prebuilt: progeny links `libproc` and
IOKit. Intel Macs build from source.

## Pin in orrery

After the release exists:

```sh
asset="progenyd_v0.1.0_darwin_arm64.tar.gz"
url="https://github.com/durandom/progeny/releases/download/v0.1.0/${asset}"
curl -fsSL -o /tmp/"${asset}" "${url}"
shasum -a 256 /tmp/"${asset}"
tar -tzf /tmp/"${asset}"
tar -xOf /tmp/"${asset}" "progenyd_v0.1.0_darwin_arm64/progenyd" | shasum -a 256
```

Feed those two hashes plus `memberPath` into `MacosLaunchAgentService`'s
`PinnedArtifact`. Deployment and launchd stay in orrery; this repo only
publishes the bytes.
