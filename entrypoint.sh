#!/bin/bash

set -ef

GROUP=

group() {
	endgroup
	echo "::group::  $1"
	GROUP=1
}

endgroup() {
	if [ -n "$GROUP" ]; then
		echo "::endgroup::"
	fi
	GROUP=
}

setup_ccache() {
	[ "${CCACHE:-0}" = '1' ] || return 0

	CCACHE_DIR="${CCACHE_DIR:-/ccache}"
	CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-1G}"
	export CCACHE_DIR

	group "ccache setup"
	mkdir -p "$CCACHE_DIR"

	if ! command -v ccache >/dev/null 2>&1; then
		echo 'CCACHE=1 but ccache is not available in the SDK container'
		return 1
	fi

	ccache -M "$CCACHE_MAXSIZE"
	ccache -s || true

	touch .config
	if [ -x ./scripts/config/conf ]; then
		./scripts/config/conf --file .config -e CCACHE -s CCACHE_DIR "$CCACHE_DIR"
	else
		{
			echo 'CONFIG_CCACHE=y'
			echo "CONFIG_CCACHE_DIR=\"$CCACHE_DIR\""
		} >> .config
	fi
	endgroup
}

restore_sdk_cache() {
	[ "${SDK_CACHE:-0}" = '1' ] || return 0

	SDK_CACHE_DIR="${SDK_CACHE_DIR:-/sdk-cache}"

	group "restore SDK cache"
	if [ ! -d "$SDK_CACHE_DIR" ]; then
		echo "SDK_CACHE=1 but SDK_CACHE_DIR does not exist: $SDK_CACHE_DIR"
		return 1
	fi

	local restored=0
	local src dest
	mkdir -p build_dir staging_dir

	if [ -d "$SDK_CACHE_DIR/build_dir" ]; then
		while IFS= read -r -d '' src; do
			dest="build_dir/$(basename "$src")"
			rm -rf "$dest"
			cp -a "$src" "$dest"
			restored=1
		done < <(find "$SDK_CACHE_DIR/build_dir" -mindepth 1 -maxdepth 1 -type d \( -name 'target-*' -o -name 'hostpkg' \) -print0)
	fi

	if [ -d "$SDK_CACHE_DIR/staging_dir" ]; then
		while IFS= read -r -d '' src; do
			dest="staging_dir/$(basename "$src")"
			rm -rf "$dest"
			cp -a "$src" "$dest"
			restored=1
		done < <(find "$SDK_CACHE_DIR/staging_dir" -mindepth 1 -maxdepth 1 -type d \( -name 'target-*' -o -name 'hostpkg' \) -print0)
	fi

	[ "$restored" = '1' ] || echo 'No SDK cache entries restored'
	endgroup
}

copy_sdk_cache_entries() {
	local cache_subdir="$1"
	local src

	mkdir -p "$SDK_CACHE_DIR/$cache_subdir"
	[ -d "$cache_subdir" ] || return 0

	while IFS= read -r -d '' src; do
		cp -a "$src" "$SDK_CACHE_DIR/$cache_subdir/"
	done < <(find "$cache_subdir" -mindepth 1 -maxdepth 1 -type d \( -name 'target-*' -o -name 'hostpkg' \) -print0)
}

prune_sdk_cache() {
	local base

	if [ -d "$SDK_CACHE_DIR/build_dir" ]; then
		while IFS= read -r -d '' base; do
			find "$base" -mindepth 1 -maxdepth 1 \
				\( -type d \( -name 'root-*' -o -name 'linux-*' \) \) \
				-prune -exec rm -rf '{}' + 2>/dev/null || true
			find "$base" \
				\( -type d \( -name 'ipkg-*' -o -name 'apk-*' -o -name '.pkgdir' \) \) \
				-prune -exec rm -rf '{}' + 2>/dev/null || true
		done < <(find "$SDK_CACHE_DIR/build_dir" -mindepth 1 -maxdepth 1 -type d -name 'target-*' -print0)
	fi

	if [ -d "$SDK_CACHE_DIR/staging_dir" ]; then
		while IFS= read -r -d '' base; do
			find "$base" -mindepth 1 -maxdepth 1 \
				\( -type d \( -name 'root-*' -o -name 'image' \) \) \
				-prune -exec rm -rf '{}' + 2>/dev/null || true
		done < <(find "$SDK_CACHE_DIR/staging_dir" -mindepth 1 -maxdepth 1 -type d -name 'target-*' -print0)
		rm -rf "$SDK_CACHE_DIR/staging_dir/packages"
	fi

	for base in "$SDK_CACHE_DIR"/build_dir "$SDK_CACHE_DIR"/staging_dir; do
		[ -d "$base" ] || continue
		find "$base" \
			\( -type d \( -name .git -o -name .svn \) \) \
			-prune -exec rm -rf '{}' + 2>/dev/null || true
		find "$base" -type f \
			\( -name '*.orig' -o -name '*.rej' \) \
			-delete 2>/dev/null || true
	done
}

save_sdk_cache() {
	[ "${SDK_CACHE:-0}" = '1' ] || return 0

	SDK_CACHE_DIR="${SDK_CACHE_DIR:-/sdk-cache}"

	group "save SDK cache"
	mkdir -p "$SDK_CACHE_DIR"
	rm -rf "$SDK_CACHE_DIR/build_dir" "$SDK_CACHE_DIR/staging_dir"

	copy_sdk_cache_entries build_dir
	copy_sdk_cache_entries staging_dir
	prune_sdk_cache

	du -sh "$SDK_CACHE_DIR" || true
	endgroup
}

replace_golang() {
	[ "${REPLACE_GOLANG:-0}" = '1' ] || return 0

	local repo="${REPLACE_GOLANG_REPO:-https://github.com/sbwml/packages_lang_golang}"
	local branch="${REPLACE_GOLANG_BRANCH:-26.x}"
	local target="feeds/packages/lang/golang"

	group "replace golang"
	if [ ! -d "feeds/packages/lang" ]; then
		echo 'REPLACE_GOLANG=1 requires the default packages feed at feeds/packages/lang'
		return 1
	fi

	rm -rf "$target"
	git clone --depth=1 --branch "$branch" "$repo" "$target"

	if [ -n "${REPLACE_GOLANG_COMMIT:-}" ]; then
		git -C "$target" fetch --depth=1 origin "$REPLACE_GOLANG_COMMIT"
		git -C "$target" -c advice.detachedHead=false checkout "$REPLACE_GOLANG_COMMIT"
	fi

	./scripts/feeds update -i packages
	endgroup
}

trap 'endgroup' ERR

group "bash setup.sh"
# snapshot containers don't ship with the SDK to save bandwidth
# run setup.sh to download and extract the SDK
[ ! -f setup.sh ] || bash setup.sh
endgroup

restore_sdk_cache

FEEDNAME="${FEEDNAME:-action}"
# Build requested packages by default, otherwise just check
BUILD="${BUILD:-1}"
BUILD_LOG="${BUILD_LOG:-1}"
AUTOREMOVE_ARGS=()
if [ "${SDK_CACHE:-0}" != '1' ]; then
	AUTOREMOVE_ARGS=(CONFIG_AUTOREMOVE=y)
fi

if [ -n "$KEY_BUILD" ]; then
	echo "$KEY_BUILD" > key-build
	CONFIG_SIGNED_PACKAGES="y"
fi

if [ -n "$PRIVATE_KEY" ]; then
	echo "$PRIVATE_KEY" > private-key.pem
	CONFIG_SIGNED_PACKAGES="y"
fi

if [ -z "$NO_DEFAULT_FEEDS" ]; then
	sed \
		-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
		-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
		-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
		feeds.conf.default > feeds.conf
fi

echo "src-link $FEEDNAME /feed/" >> feeds.conf

ALL_CUSTOM_FEEDS="$FEEDNAME "
#shellcheck disable=SC2153
for EXTRA_FEED in $EXTRA_FEEDS; do
	echo "$EXTRA_FEED" | tr '|' ' ' >> feeds.conf
	ALL_CUSTOM_FEEDS+="$(echo "$EXTRA_FEED" | cut -d'|' -f2) "
done

group "feeds.conf"
cat feeds.conf
endgroup

group "feeds update -a"
./scripts/feeds update -a
endgroup

replace_golang

setup_ccache

group "make defconfig"
make defconfig
endgroup

if [ -z "$PACKAGES" ]; then
	# compile all packages in feed
	for FEED in $ALL_CUSTOM_FEEDS; do
		group "feeds install -p $FEED -f -a"
		./scripts/feeds install -p "$FEED" -f -a
		endgroup
	done

	RET=0

	make \
		BUILD_LOG="$BUILD_LOG" \
		CONFIG_SIGNED_PACKAGES="$CONFIG_SIGNED_PACKAGES" \
		IGNORE_ERRORS="$IGNORE_ERRORS" \
		"${AUTOREMOVE_ARGS[@]}" \
		V="$V" \
		-j "$(nproc)" || RET=$?
else
	# compile specific packages with checks
	for PKG in $PACKAGES; do
		for FEED in $ALL_CUSTOM_FEEDS; do
			group "feeds install -p $FEED -f $PKG"
			./scripts/feeds install -p "$FEED" -f "$PKG"
			endgroup
		done

		group "make package/$PKG/download"
		make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			"package/$PKG/download" V=s
		endgroup

		[ "$BUILD" = '1' ] && group "make package/$PKG/check"
		make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			"package/$PKG/check" V=s 2>&1 | \
				tee logtmp

		RET=${PIPESTATUS[0]}
		[ "$BUILD" = '1' ] && endgroup

		if [ "$RET" -ne 0 ]; then
			echo 'Package check failed'
			exit "$RET"
		elif [ "$BUILD" = 0 ]; then
			echo 'Package check successful'
		fi

		badhash_msg="HASH does not match "
		badhash_msg+="|HASH uses deprecated hash,"
		badhash_msg+="|HASH is missing,"
		if grep -qE "$badhash_msg" logtmp; then
			echo "Package HASH check failed"
			exit 1
		fi

		PATCHES_DIR=$(find /feed -path "*/$PKG/patches")
		if [ -d "$PATCHES_DIR" ] && [ -z "$NO_REFRESH_CHECK" ]; then
			[ "$BUILD" = '1' ] && group "make package/$PKG/refresh"
			make \
				BUILD_LOG="$BUILD_LOG" \
				IGNORE_ERRORS="$IGNORE_ERRORS" \
				"package/$PKG/refresh" V=s
			[ "$BUILD" = '1' ] && endgroup

			if ! git -C "$PATCHES_DIR" diff --quiet -- .; then
				echo "Dirty patches detected, please refresh and review the diff"
				git -C "$PATCHES_DIR" checkout -- .
				exit 1
			fi

			if [ "${SDK_CACHE:-0}" = '1' ]; then
				echo "Skipping make package/$PKG/clean because SDK_CACHE=1"
			else
				group "make package/$PKG/clean"
				make \
					BUILD_LOG="$BUILD_LOG" \
					IGNORE_ERRORS="$IGNORE_ERRORS" \
					"package/$PKG/clean" V=s
				endgroup
			fi
		fi

		FILES_DIR=$(find /feed -path "*/$PKG/files")
		if [ -d "$FILES_DIR" ] && [ -z "$NO_SHFMT_CHECK" ]; then
			find "$FILES_DIR" -name "*.init" -exec shfmt -w -sr -s '{}' \;
			if ! git -C "$FILES_DIR" diff --quiet -- .; then
				echo "init script must be formatted. Please run through shfmt -w -sr -s"
				git -C "$FILES_DIR" checkout -- .
				exit 1
			fi
		fi
	done

	if [ "$BUILD" != '1' ]; then
		echo 'Skipping build'
		exit
	fi

	make \
		-f .config \
		-f tmp/.packagedeps \
		-f <(echo "\$(info \$(sort \$(package-y) \$(package-m)))"; echo -en "a:\n\t@:") \
			| tr ' ' '\n' > enabled-package-subdirs.txt

	RET=0

	for PKG in $PACKAGES; do
		if ! grep -m1 -qE "(^|/)$PKG$" enabled-package-subdirs.txt; then
			echo "::warning file=$PKG::Skipping $PKG due to unsupported architecture"
			continue
		fi

		make \
			BUILD_LOG="$BUILD_LOG" \
			IGNORE_ERRORS="$IGNORE_ERRORS" \
			"${AUTOREMOVE_ARGS[@]}" \
			V="$V" \
			-j "$(nproc)" \
			"package/$PKG/compile" || {
				RET=$?
				break
			}
	done
fi

if [ "$INDEX" = '1' ];then
	group "make package/index"
	make \
		CONFIG_SIGNED_PACKAGES="$CONFIG_SIGNED_PACKAGES" \
		V=s \
		package/index
	endgroup
fi

if [ "${CCACHE:-0}" = '1' ] && command -v ccache >/dev/null 2>&1; then
	group "ccache stats"
	ccache -s || true
	endgroup
fi

if [ -d bin/ ]; then
	mv bin/ /artifacts/
fi

if [ -d logs/ ]; then
	mv logs/ /artifacts/
fi

save_sdk_cache

exit "$RET"
