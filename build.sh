#!/bin/bash

yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
gre='\e[0;32m'
ZIMG=./out/arch/arm64/boot/Image
OUTPUT_DIR=./../Paradox_release

no_mkclean=false
no_ccache=false
no_thinlto=false
with_ksu=false
make_flags=

while [ $# != 0 ]; do
	case $1 in
		"--noclean") no_mkclean=true;;
		"--noccache") no_ccache=true;;
		"--nolto") no_thinlto=true;;
		"--ksu") with_ksu=true;;
		"--") {
			shift
			while [ $# != 0 ]; do
				make_flags="${make_flags} $1"
				shift
			done
			break
		};;
		*) {
			cat <<EOF
Usage: $0 <operate>
operate:
    --noclean  : build without run "make mrproper"
    --noccache : build without ccache
    --nolto    : build without LTO
    --ksu      : build with KernelSU support
    -- <args>  : parameters passed directly to make
EOF
			exit 1
		};;
	esac
	shift
done

export CLANG_PATH=/home/avider/build_toolchain/clang-r536225
export PATH=${CLANG_PATH}/bin:${PATH}

export ARCH=arm64
export KBUILD_BUILD_HOST="wsl2"
export KBUILD_BUILD_USER="avider"

export LOCALVERSION=-test
$with_ksu && export LOCALVERSION="${LOCALVERSION}-ksu"

ccache_=
(! $no_ccache) && ccache_=`which ccache` || echo -e "${yellow}Warning: ccache is not used! $white"

if [ -n "$ccache_" ]; then
	orig_cache_hit_d=$(	ccache -s | grep 'cache hit (direct)'		| awk '{print $4}')
	orig_cache_hit_p=$(	ccache -s | grep 'cache hit (preprocessed)'	| awk '{print $4}')
	orig_cache_miss=$(	ccache -s | grep 'cache miss'			| awk '{print $3}')
	orig_cache_hit_rate=$(	ccache -s | grep 'cache hit rate'		| awk '{print $4 " %"}')
	orig_cache_size=$(	ccache -s | grep '^cache size'			| awk '{print $3 " " $4}')
fi

rm -f $ZIMG

$no_mkclean || make mrproper O=out || exit 1
make vendor/xiaomi/nabu_inflated_defconfig O=out || exit 1

$no_thinlto && {
	./scripts/config --file out/.config -d THINLTO
	./scripts/config --file out/.config -d LTO_CLANG
	./scripts/config --file out/.config -e LTO_NONE
	./scripts/config --file out/.config -e RANDOMIZE_MODULE_REGION_FULL
}

$with_ksu && {
	./scripts/config --file out/.config -e KSU
	./scripts/config --file out/.config -d KSU_DEBUG
}

Start=$(date +"%s")

make -j$(nproc --all) \
	O=out \
	CC="${ccache_} clang" \
	AS=llvm-as \
	LD=ld.lld \
	AR=llvm-ar \
	NM=llvm-nm \
	STRIP=llvm-strip \
	OBJCOPY=llvm-objcopy \
	OBJDUMP=llvm-objdump \
	CROSS_COMPILE="/home/avider/build_toolchain/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-" \
	CROSS_COMPILE_ARM32="/home/avider/build_toolchain/arm-gnu-toolchain-14.3.Rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-" \
	${make_flags}

exit_code=$?
End=$(date +"%s")
Diff=$(($End - $Start))

if [ -f $ZIMG ]; then
	mkdir -p $OUTPUT_DIR
	cp -f ./out/arch/arm64/boot/Image.gz $OUTPUT_DIR/Image.gz
	cp -f ./out/arch/arm64/boot/dts/qcom/sdmmagpie.dtb $OUTPUT_DIR/dtb
	cp -f ./out/arch/arm64/boot/dtbo.img $OUTPUT_DIR/dtbo.img
	which avbtool &>/dev/null && {
		avbtool add_hash_footer \
			--partition_name dtbo \
			--partition_size $((32 * 1024 * 1024)) \
			--image $OUTPUT_DIR/dtbo.img
	} || {
		echo -e "${yellow}Warning: Skip adding hashes and footer to dtbo image! $white"
	}
	cat ./out/modules.order | while read line; do
		module_file=./out/${line#*/}
		[ -f $module_file ] && cp -f $module_file $OUTPUT_DIR
	done
	for f in `ls -1 $OUTPUT_DIR | grep '.ko$'`; do
		llvm-strip -S ${OUTPUT_DIR}/$f &
	done
	wait
	echo -e "$gre << Build completed in $(($Diff / 60)) minutes and $(($Diff % 60)) seconds >> \n $white"
	if [ -n "$ccache_" ]; then
		now_cache_hit_d=$(	ccache -s | grep 'cache hit (direct)'		| awk '{print $4}')
		now_cache_hit_p=$(	ccache -s | grep 'cache hit (preprocessed)'	| awk '{print $4}')
		now_cache_miss=$(	ccache -s | grep 'cache miss'			| awk '{print $3}')
		now_cache_hit_rate=$(	ccache -s | grep 'cache hit rate'		| awk '{print $4 " %"}')
		now_cache_size=$(	ccache -s | grep '^cache size'			| awk '{print $3 " " $4}')
		echo -e "${yellow}ccache status:${white}"
		echo -e "\tcache hit (direct)\t\t"	$orig_cache_hit_d	"\t${gre}->${white}\t"	$now_cache_hit_d	"\t${gre}+${white} $((now_cache_hit_d - orig_cache_hit_d))"
		echo -e "\tcache hit (preprocessed)\t"	$orig_cache_hit_p	"\t${gre}->${white}\t"	$now_cache_hit_p	"\t${gre}+${white} $((now_cache_hit_p - orig_cache_hit_p))"
		echo -e "\tcache miss\t\t\t"		$orig_cache_miss	"\t${gre}->${white}\t"	$now_cache_miss		"\t${gre}+${white} $((now_cache_miss - orig_cache_miss))"
		echo -e "\tcache hit rate\t\t\t"	$orig_cache_hit_rate	"\t${gre}->${white}\t"	$now_cache_hit_rate
		echo -e "\tcache size\t\t\t"		$orig_cache_size	"\t${gre}->${white}\t"	$now_cache_size
	fi
else
	echo -e "$red << Failed to compile Image.gz-dtb, fix the errors first >>$white"
	exit $exit_code
fi
