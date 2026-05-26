# OpenWrt GitHub Action SDK (MyWRT Fork)

> **This is a fork of [openwrt/gh-action-sdk](https://github.com/openwrt/gh-action-sdk).**
>
> **Differences from upstream:**
> - **ccache support**: set `CCACHE: '1'` to enable compiler caching across runs via GitHub Actions cache, with configurable size (`CCACHE_MAXSIZE`) and key prefix (`CCACHE_CACHE_PREFIX`).
> - **Docker layer cache disabled**: the SDK wrapper image is built without BuildKit's GitHub Actions cache so repository cache quota can be reserved for ccache.

GitHub CI action to build packages via SDK using official OpenWrt SDK Docker
containers. This is primary used to test build OpenWrt repositories but can
also be used for downstream projects maintaining their own package
repositories.

This fork intentionally does not cache Docker image layers. The upstream action
uses BuildKit's GitHub Actions cache for the small SDK wrapper image, but those
cached SDK layers can consume most of a repository's default 10 GB Actions cache
quota. Prefer enabling ccache for compiler outputs instead, since that usually
has a larger impact on repeated package build time.

## Example usage

The following YAML code can be used to build all packages of a repository and
store created `ipk` files as artifacts.

```yaml
name: Test Build

on:
  pull_request:
    branches:
      - main

jobs:
  build:
    name: ${{ matrix.arch }} build
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch:
          - x86_64
          - mips_24kc

    steps:
      - uses: actions/checkout@v2
        with:
          fetch-depth: 0

      - name: Build
        uses: mywrt/gh-action-sdk@main
        env:
          ARCH: ${{ matrix.arch }}

      - name: Store packages
        uses: actions/upload-artifact@v2
        with:
          name: ${{ matrix.arch}}-packages
          path: bin/packages/${{ matrix.arch }}/packages/*.ipk
```

## Environmental variables

The action reads a few env variables:

* `ARCH` determines the used OpenWrt SDK Docker container.
  E.g. `x86_64` or `x86_64-22.03.2`.
* `ARTIFACTS_DIR` determines where built packages and build logs are saved.
  Defaults to the default working directory (`GITHUB_WORKSPACE`).
* `BUILD_LOG` stores build logs in `./logs`.
* `CCACHE` enables ccache when set to `1`. The action restores and saves a
  GitHub Actions cache for the selected SDK container and architecture.
* `CCACHE_CACHE_PREFIX` overrides the GitHub Actions cache key prefix used for
  ccache. Defaults to the runner OS, SDK container, and architecture.
* `CCACHE_DIR` sets the host-side ccache directory cached by GitHub Actions.
  Defaults to `$GITHUB_WORKSPACE/.ccache` and is mounted as `/ccache` in the SDK
  container.
* `CCACHE_MAXSIZE` sets the ccache maximum size. Defaults to `1G`.
* `CCACHE_COMPILERCHECK` and `CCACHE_RECACHE` are passed through to ccache when
  ccache is enabled.
* `CONTAINER` can set other SDK containers than `openwrt/sdk`.
* `EXTRA_FEEDS` are added to the `feeds.conf`, where `|` are replaced by white
  spaces.
* `FEED_DIR` used in the created `feeds.conf` for the current repo. Defaults to
  the default working directory (`GITHUB_WORKSPACE`).
* `FEEDNAME` used in the created `feeds.conf` for the current repo. Defaults to
  `action`.
* `IGNORE_ERRORS` can ignore failing packages builds.
* `INDEX` makes the action build the package index. Default is 0. Set to 1 to enable.
* `KEY_BUILD` can be a private Signify/`usign` key to sign the packages (ipk) feed.
* `PRIVATE_KEY` can be a private key to sign the packages (apk) feed.
* `NO_DEFAULT_FEEDS` disable adding the default SDK feeds
* `NO_REFRESH_CHECK` disable check if patches need a refresh.
* `NO_SHFMT_CHECK` disable check if init files are formated
* `PACKAGES` (Optional) specify the list of packages (space separated) to be built
* `V` changes the build verbosity level.
