#!/bin/bash

# 颜色定义
yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
gre='\e[0;32m'

# 路径定义
ZIMG=./out/arch/arm64/boot/Image
OUTPUT_DIR=./../Release/Avid_release
DTB_SOURCE_DIR=./out/arch/arm64/boot/dts/qcom
DTB_TARGET=$OUTPUT_DIR/dtb

# 参数处理
ccache_=`which ccache`
no_mkclean=false
use_thinlto=false
make_flags=

while [ $# != 0 ]; do
    case $1 in
        "--noclean") no_mkclean=true ;;
        "--noccache") ccache_= ;;
        "--thinlto") use_thinlto=true ;;
        "--") {
            shift
            while [ $# != 0 ]; do
                make_flags="${make_flags} $1"
                shift
            done
            break
        } ;;
        *) {
            cat <<EOF
Usage: $0 <operate>
operate:
    --noclean   : build without run "make mrproper"
    --noccache  : build without ccache
    --thinlto   : build using ThinLTO (default is Full LTO)
    -- <args>   : parameters passed directly to make
EOF
            exit 1
        } ;;
    esac
    shift
done

if [ -z "$ccache_" ]; then
    echo -e "${yellow}Warning: ccache is not used!${white}"
fi

# 环境设置
export CLANG_PATH=/home/avider/android_kernel/build_toolchain/clang-r536225
export PATH=${CLANG_PATH}/bin:${PATH}

export ARCH=arm64
export KBUILD_BUILD_HOST="wsl2"
export KBUILD_BUILD_USER="avider"

touch .scmversion
current_date=$(date +"%Y%m%d")
export LOCALVERSION="-$current_date"

# 记录 ccache 状态
if [ -n "$ccache_" ]; then
    orig_cache_hit_d=$(  ccache -s | grep 'cache hit (direct)'      | awk '{print $4}')
    orig_cache_hit_p=$(  ccache -s | grep 'cache hit (preprocessed)'| awk '{print $4}')
    orig_cache_miss=$(   ccache -s | grep 'cache miss'              | awk '{print $3}')
    orig_cache_hit_rate=$(ccache -s | grep 'cache hit rate'         | awk '{print $4 " %"}')
    orig_cache_size=$(   ccache -s | grep '^cache size'             | awk '{print $3 " " $4}')
fi

# 清理和配置
rm -f $ZIMG
$no_mkclean || make mrproper O=out || exit 1
make vendor/xiaomi/nabu_inflated_defconfig O=out || exit 1

# 设置 LTO 模式（仅 Full LTO 或 ThinLTO）
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

# 其他优化配置
./scripts/config --file out/.config -e RANDOMIZE_MODULE_REGION_FULL

# 应用配置
make O=out olddefconfig

# 编译开始
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
    CROSS_COMPILE="/home/avider/android_kernel/build_toolchain/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-" \
    CROSS_COMPILE_ARM32="arm-linux-gnueabihf-" \
    ${make_flags}

exit_code=$?
End=$(date +"%s")
Diff=$(($End - $Start))

# 构建成功时处理产物
if [ -f $ZIMG ]; then
    mkdir -p $OUTPUT_DIR

    cp -f ./out/arch/arm64/boot/Image $OUTPUT_DIR/Image

    # 合并 DTB 文件
    DTB_FILES=($DTB_SOURCE_DIR/sm8150*.dtb)
    echo -e "${yellow}Merging DTB files...${white}"
    cat "${DTB_FILES[@]}" > $DTB_TARGET || {
        echo -e "${red}Failed to merge DTB files!${white}"
        exit 1
    }
    echo -e "${gre}DTB files merged successfully to $DTB_TARGET${white}"

    # 处理 dtbo.img
    cp -f ./out/arch/arm64/boot/dtbo.img $OUTPUT_DIR/dtbo.img
    which avbtool &>/dev/null && {
        avbtool add_hash_footer \
            --partition_name dtbo \
            --partition_size $((32 * 1024 * 1024)) \
            --image $OUTPUT_DIR/dtbo.img
    } || {
        echo -e "${yellow}Warning: Skip adding hashes and footer to dtbo image!${white}"
    }

    # 复制模块
    cat ./out/modules.order | while read line; do
        module_file=./out/${line#*/}
        [ -f $module_file ] && cp -f $module_file $OUTPUT_DIR
    done

    # Strip 模块
    for f in `ls -1 $OUTPUT_DIR | grep '.ko$'`; do
        llvm-strip -S ${OUTPUT_DIR}/$f &
    done
    wait

    echo -e "$gre << Build completed in $(($Diff / 60)) minutes and $(($Diff % 60)) seconds >> \n $white"

    # 显示 ccache 状态
    if [ -n "$ccache_" ]; then
        now_cache_hit_d=$(  ccache -s | grep 'cache hit (direct)'      | awk '{print $4}')
        now_cache_hit_p=$(  ccache -s | grep 'cache hit (preprocessed)'| awk '{print $4}')
        now_cache_miss=$(   ccache -s | grep 'cache miss'              | awk '{print $3}')
        now_cache_hit_rate=$(ccache -s | grep 'cache hit rate'         | awk '{print $4 " %"}')
        now_cache_size=$(   ccache -s | grep '^cache size'             | awk '{print $3 " " $4}')
        echo -e "${yellow}ccache status:${white}"
        echo -e "\tcache hit (direct)\t\t"  $orig_cache_hit_d   "\t${gre}->${white}\t"  $now_cache_hit_d   "\t${gre}+${white} $((now_cache_hit_d - orig_cache_hit_d))"
        echo -e "\tcache hit (preprocessed)\t"  $orig_cache_hit_p   "\t${gre}->${white}\t"  $now_cache_hit_p   "\t${gre}+${white} $((now_cache_hit_p - orig_cache_hit_p))"
        echo -e "\tcache miss\t\t\t"      $orig_cache_miss  "\t${gre}->${white}\t"  $now_cache_miss    "\t${gre}+${white} $((now_cache_miss - orig_cache_miss))"
        echo -e "\tcache hit rate\t\t\t"  $orig_cache_hit_rate "\t${gre}->${white}\t"  $now_cache_hit_rate
        echo -e "\tcache size\t\t\t"      $orig_cache_size "\t${gre}->${white}\t"  $now_cache_size
    fi
else
    echo -e "$red << Failed to compile Image, fix the errors first >>$white"
    exit $exit_code
fi
