#!/bin/bash

# 颜色定义
yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
gre='\e[0;32m'

# 路径定义
ZIMG=./out/arch/arm64/boot/Image
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/../Release/Avid_release}"
DTB_SOURCE_DIR=./out/arch/arm64/boot/dts/qcom
DTB_TARGET="$OUTPUT_DIR/dtb"

# 参数处理
ccache_=$(which ccache 2>/dev/null || echo "")
no_mkclean=false
use_thinlto=false
make_flags=""

while [ $# -gt 0 ]; do
    case $1 in
        --noclean) no_mkclean=true ;;
        --noccache) ccache_="" ;;
        --thinlto) use_thinlto=true ;;
        --) shift; while [ $# -gt 0 ]; do make_flags="$make_flags $1"; shift; done; break ;;
        *)
            cat <<EOF
Usage: $0 [options]
Options:
  --noclean    : Skip 'make mrproper'
  --noccache   : Disable ccache usage
  --thinlto    : Use ThinLTO instead of Full LTO
  -- <args>    : Pass remaining args directly to make
EOF
            exit 1
            ;;
    esac
    shift
done

if [ -z "$ccache_" ]; then
    echo -e "${yellow}Warning: ccache is not used!${white}"
fi

# 使用系统默认 clang 和 ld.lld
CLANG_PATH="/usr/bin"

export PATH="$CLANG_PATH:$PATH"

# 检测交叉编译工具链是否存在
if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
    echo -e "${red}Error: aarch64-linux-gnu-gcc not found in PATH${white}"
    echo -e "${yellow}Try installing with:${white} sudo apt install gcc-aarch64-linux-gnu"
    exit 1
fi
if ! command -v arm-linux-gnueabihf-gcc &>/dev/null; then
    echo -e "${red}Error: arm-linux-gnueabihf-gcc not found in PATH${white}"
    echo -e "${yellow}Try installing with:${white} sudo apt install gcc-arm-linux-gnueabihf"
    exit 1
fi

# 环境变量
export ARCH=arm64
export KBUILD_BUILD_HOST=$(hostname)
export KBUILD_BUILD_USER=$(whoami)

touch .scmversion
current_date=$(date +"%Y%m%d")
export LOCALVERSION="-$current_date"

# 记录 ccache 状态
if [ -n "$ccache_" ]; then
    orig_cache_hit_d=$(ccache -s | grep 'cache hit (direct)'       | awk '{print $4}')
    orig_cache_hit_p=$(ccache -s | grep 'cache hit (preprocessed)' | awk '{print $4}')
    orig_cache_miss=$(ccache -s | grep 'cache miss'               | awk '{print $3}')
    orig_cache_hit_rate=$(ccache -s | grep 'cache hit rate'        | awk '{print $4 " %"}')
    orig_cache_size=$(ccache -s | grep '^cache size'              | awk '{print $3 " " $4}')
fi

# 清理和配置
rm -f "$ZIMG"
if ! $no_mkclean; then
    echo -e "${yellow}Running make mrproper...${white}"
    make mrproper O=out || exit 1
fi

echo -e "${yellow}Running make nabu_defconfig...${white}"
make nabu_defconfig O=out || exit 1

# LTO 配置
if $use_thinlto; then
    echo -e "${yellow}Using ThinLTO mode...${white}"
    ./scripts/config --file out/.config -e LTO_CLANG
    ./scripts/config --file out/.config -e THINLTO
    ./scripts/config --file out/.config -d LTO_NONE
else
    echo -e "${yellow}Using Full LTO mode...${white}"
    ./scripts/config --file out/.config -e LTO_CLANG
    ./scripts/config --file out/.config -d THINLTO
    ./scripts/config --file out/.config -d LTO_NONE
fi

# 额外配置
./scripts/config --file out/.config -e RANDOMIZE_MODULE_REGION_FULL

make O=out olddefconfig

# 编译开始
Start=$(date +"%s")

make -j$(nproc) \
    LLVM=1 LLVM_IAS=1 \
    O=out \
    CC="${ccache_} clang" \
    AS=llvm-as \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    STRIP=llvm-strip \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    CROSS_COMPILE="aarch64-linux-gnu-" \
    CROSS_COMPILE_ARM32="arm-linux-gnueabihf-" \
    ${make_flags}

exit_code=$?
End=$(date +"%s")
Diff=$((End - Start))

if [ -f "$ZIMG" ]; then
    mkdir -p "$OUTPUT_DIR"
    cp -f ./out/arch/arm64/boot/Image "$OUTPUT_DIR/Image"

    # 合并 DTB
    DTB_FILES=($DTB_SOURCE_DIR/sm8150*.dtb)
    echo -e "${yellow}Merging DTB files...${white}"
    cat "${DTB_FILES[@]}" > "$DTB_TARGET" || {
        echo -e "${red}Failed to merge DTB files!${white}"
        exit 1
    }
    echo -e "${gre}DTB files merged successfully to $DTB_TARGET${white}"

    # 处理 dtbo.img
    cp -f ./out/arch/arm64/boot/dtbo.img "$OUTPUT_DIR/dtbo.img"
    if which avbtool &>/dev/null; then
        avbtool add_hash_footer \
            --partition_name dtbo \
            --partition_size $((32 * 1024 * 1024)) \
            --image "$OUTPUT_DIR/dtbo.img"
    else
        echo -e "${yellow}Warning: Skip adding hashes and footer to dtbo image!${white}"
    fi

    # 复制模块
    while read -r line; do
        module_file="./out/${line#*/}"
        [ -f "$module_file" ] && cp -f "$module_file" "$OUTPUT_DIR"
    done < ./out/modules.order

    # Strip 模块
    for f in $(ls -1 "$OUTPUT_DIR" | grep '\.ko$'); do
        llvm-strip -S "$OUTPUT_DIR/$f" &
    done
    wait

    echo -e "${gre}<< Build completed in $((Diff / 60)) minutes and $((Diff % 60)) seconds >>${white}"

    if [ -n "$ccache_" ]; then
        now_cache_hit_d=$(ccache -s | grep 'cache hit (direct)'       | awk '{print $4}')
        now_cache_hit_p=$(ccache -s | grep 'cache hit (preprocessed)' | awk '{print $4}')
        now_cache_miss=$(ccache -s | grep 'cache miss'               | awk '{print $3}')
        now_cache_hit_rate=$(ccache -s | grep 'cache hit rate'        | awk '{print $4 " %"}')
        now_cache_size=$(ccache -s | grep '^cache size'              | awk '{print $3 " " $4}')
        echo -e "${yellow}ccache status:${white}"
        echo -e "\tcache hit (direct)\t\t$orig_cache_hit_d\t${gre}->${white}\t$now_cache_hit_d\t${gre}+${white} $((now_cache_hit_d - orig_cache_hit_d))"
        echo -e "\tcache hit (preprocessed)\t$orig_cache_hit_p\t${gre}->${white}\t$now_cache_hit_p\t${gre}+${white} $((now_cache_hit_p - orig_cache_hit_p))"
        echo -e "\tcache miss\t\t\t$orig_cache_miss\t${gre}->${white}\t$now_cache_miss\t${gre}+${white} $((now_cache_miss - orig_cache_miss))"
        echo -e "\tcache hit rate\t\t\t$orig_cache_hit_rate\t${gre}->${white}\t$now_cache_hit_rate"
        echo -e "\tcache size\t\t\t$orig_cache_size\t${gre}->${white}\t$now_cache_size"
    fi
else
    echo -e "${red}<< Failed to compile Image, fix the errors first >>${white}"
    exit $exit_code
fi
