#!/bin/bash
#
# update_kernel.sh: (c) 2017 Jonas Gorski <jonas.gorski@gmail.com>
# parallel mod by graysky2 2022
# Licensed under the terms of the GNU GPL License version 2

umask 022

BUILD=0
BUILD_ARGS=
VERBOSE=w
TEST=0
UPDATE=0

KERNEL=
PATCHVER=

if [[ "$(pwd)" = "/incoming/openwrt" ]]; then
	echo "do not run here!"
	exit 1
fi

while [ $# -gt 0 ]; do
	case $1 in
		-b|--build)
			BUILD=1
			shift
			BUILD_ARGS=$1
			;;
		-q|--quiet)
			VERBOSE=
			;;
		-t|--test)
			TEST=1
			;;
		-u|--update)
			UPDATE=1
			;;
		-v|--verbose)
			VERBOSE=ws
			;;
		[1-9]*)
			if [ -z "$KERNEL" ]; then
				KERNEL=$1
			elif [ -z "$PATCHVER" ]; then
				PATCHVER=$1
			else
				exit 1
			fi
			;;
		*)
			break
			;;

	esac

	shift
done

if [ -z "$KERNEL" ]; then
	echo "usage: $0 [<options>...] <patchver> [<version>]"
	echo "example: $0 3.18 3.18.30"
	echo "If <version> is not given, it will try to find out the latest from kernel.org"
	echo ""
	echo "valid options:"
	echo "-b|--build <args> also do a test build with <args> as extra arguments (e.g. -j 3)"
	echo "-q|--quiet        less output"
	echo "-t|--test         don't do anything, just print what it would do"
	echo "-u|--update       update include/kernel-version.mk after a successful run"
	echo "-v|--verbose      more output (pass V=ws to all commands)"
	exit 1
fi

if [ -z "$PATCHVER" ]; then
	if [ -n "$(which curl)" ]; then
		DL_CMD="curl -s "
	fi

	if [ -n "$(which wget)" ]; then
		DL_CMD="wget -O - -q "
	fi

	if [ -z "$DL_CMD" ]; then
		echo "Failed to find a suitable download program. Please install either curl or wget." >&2
		exit 1
	fi

	# https://www.kernel.org/feeds/kdist.xml
	# $(curl -s https://www.kernel.org/feeds/kdist.xml | sed -ne 's|^.*"html_url": "\(.*/commit/.*\)",|\1.patch|p')
	# curl -s "https://www.kernel.org/feeds/kdist.xml"
	CURR_VERS=$($DL_CMD "https://www.kernel.org/feeds/kdist.xml" | sed -ne 's|^.*title>\([1-9][^\w]*\): .*|\1|p')

	for ver in $CURR_VERS; do
		case $ver in
			"$KERNEL"*)
				PATCHVER=$ver
				;;
		esac

		if [ -n "$PATCHVER" ]; then
			break
		fi
	done

	if [ -z "$PATCHVER" ]; then
		echo "Failed to find the latest release on kernel.org, please specify the release manually" >&2
		exit 1
	fi
fi

if [ "$TEST" -eq 1 ]; then
	CMD="echo"
fi

doit() {
  [[ -d build_dir ]] || mkdir build_dir

	if grep -q "broken" target/linux/"$target"/Makefile; then
    echo " ---> skipping $target (broken)"

    return
  fi

	if [ -e tmp/"${target}_${PATCHVER}"_done ]; then
    echo "found done file tmp/${target}_${PATCHVER}_done so quitting"
    return
	fi

  live=$(pwd)
  base=$(dirname "$(pwd)")
  if [[ -d "$base/targets/$target" ]]; then
    rm -rf "$base/targets/$target"
  fi
  
  mkdir -p "$base/targets/$target" || exit 1
  cd "$base/targets/$target" || exit 1
  for dir in LICENSES config dl include package scripts staging_dir target tmp toolchain tools; do
    ln -s "$live/$dir" "$dir"
  done

  for file in BSDmakefile COPYING Config.in Makefile feeds.conf.default rules.mk update_kernel.sh; do
    ln -s "$live/$file" "$file"
  done

	grep -q "${PATCHVER}" target/linux/"$target"/Makefile \
    || [ -f target/linux/"$target"/config-"${KERNEL}" ] \
    || [ -d target/linux/"$target"/patches-"${KERNEL}" ] &&
    
    {
		echo " ---> refreshing $target"
		$CMD echo "CONFIG_TARGET_$target=y" > .config || exit 1
		$CMD echo "CONFIG_ALL_KMODS=y" >> .config || exit 1
		$CMD make defconfig KERNEL_PATCHVER="${KERNEL}" || exit 1

		if [ ! -f tmp/"${target}_${PATCHVER}_refreshed" ]; then
			$CMD make target/linux/refresh V="$VERBOSE" KERNEL_PATCHVER="${KERNEL}" LINUX_VERSION="${PATCHVER}" LINUX_KERNEL_HASH=skip || exit 1
			$CMD make target/linux/prepare V="$VERBOSE" KERNEL_PATCHVER="${KERNEL}" LINUX_VERSION="${PATCHVER}" || exit 1
			$CMD touch tmp/"${target}_${PATCHVER}_refreshed"
		fi

    if [ "$BUILD" = "1" ]; then
			echo "building $target ... "
			$CMD make V="$VERBOSE" KERNEL_PATCHVER="${KERNEL}" LINUX_VERSION="${PATCHVER}" "$BUILD_ARGS" || exit 1
		fi
		
    $CMD make target/linux/clean
		$CMD touch tmp/"${target}_${PATCHVER}_done"
	} || echo " ---> skipping $target (no support for $KERNEL)" ; echo

  # finished without error
  mv "$live/nohup.out.$target" "$live/success-nohup.out.$target"
}

updatesums() {
if [ "$UPDATE" -eq 1 ]; then
	NEWVER="${PATCHVER#"$KERNEL"}"
	if [ "$TEST" -eq 1 ]; then
		echo ./staging_dir/host/bin/mkhash sha256 dl/linux-"$PATCHVER".tar.xz
	fi

	if [ -f dl/linux-"$PATCHVER".tar.xz ]; then
		CHECKSUM=$(./staging_dir/host/bin/mkhash sha256 dl/linux-"$PATCHVER".tar.xz)
	fi

	if [ -f include/kernel-"${KERNEL}" ]; then
		# split version files
		KERNEL_VERSION_FILE=include/kernel-"${KERNEL}"
	else
		# unified version file
		KERNEL_VERSION_FILE=include/kernel-version.mk
	fi

	$CMD ./staging_dir/host/bin/sed -i "${KERNEL_VERSION_FILE}" \
		-e "s|LINUX_VERSION-${KERNEL} =.*|LINUX_VERSION-${KERNEL} = ${NEWVER}|" \
		-e "s|LINUX_KERNEL_HASH-${KERNEL}.*|LINUX_KERNEL_HASH-${PATCHVER} = ${CHECKSUM}|"
fi
}

# setup first then parallalize
[[ -d tmp ]] || mkdir tmp
echo CONFIG_TARGET_bcm27xx=y > .config
echo CONFIG_ALL_KMODS=y >> .config
make defconfig || exit 1

# get source tarball first then parallalize
make target/linux/download || exit 1
rm .config*

mapfile -t targets < <(find target/linux -maxdepth 1 -type d | grep -o '[^/]*$' | sort)
# generic target is bogus
targets=( "${targets[@]/generic}" )

echo "Refreshing Kernel $KERNEL to release $PATCHVER ..."
for target in "${targets[@]}"; do
  echo " >>> tail -f nohup.out.$target"
  
  # https://www.unix.com/unix-and-linux-applications/157648-nohup-versus-functions.html
  ( trap "true" HUP ; doit ) > "nohup.out.$target" 2>/dev/null </dev/null & disown
  sleep 5s
done

updatesums
