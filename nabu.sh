#!/bin/bash
#set -e

## Copy this script inside the kernel directory
LINKER="lld"
DIR=$(readlink -f .)
MAIN=$(readlink -f ${DIR}/..)
KERNEL_DEFCONFIG=nabu_defconfig
CLANG_PATH=${CLANG_PATH:-$HOME/build_toolchain/clang-r522817/bin}
export PATH="$CLANG_PATH:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_COMPILER_STRING="$($MAIN/custom-clang/bin/clang --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')"

if ! [ -d "$MAIN/custom-clang" ]; then
    echo "Proton clang not found! Download from https://github.com/Mandi-Sa/clang"
fi

KERNEL_DIR=$(pwd)
ZIMAGE_DIR="$KERNEL_DIR/out/arch/arm64/boot"
# Speed up build process
MAKE="./makeparallel"
BUILD_START=$(date +"%s")
blue='\033[0;34m'
cyan='\033[0;36m'
yellow='\033[0;33m'
red='\033[0;31m'
nocol='\033[0m'

echo -e "$blue***********************************************"
echo "          Initializing Kernel Compilation          "
echo -e "***********************************************$nocol"

# Create a function to revert changes
revert_changes() {
    sed -i 's/qcom,mdss-pan-physical-width-dimension = <1474>;$/qcom,mdss-pan-physical-width-dimension = <147>;/' arch/arm64/boot/dts/qcom/dsi-panel-k82-42-02-0a-video.dtsi
    sed -i 's/qcom,mdss-pan-physical-height-dimension = <2359>;$/qcom,mdss-pan-physical-height-dimension = <236>;/' arch/arm64/boot/dts/qcom/dsi-panel-k82-42-02-0a-video.dtsi
}

# Prompt the user for the build type (MIUI or AOSP)
echo "Choose the build type:"
echo "1. MIUI"
echo "2. AOSP"
read -p "Enter the number of your choice: " build_choice

zip_name=""
if [ "$build_choice" = "1" ]; then
    # Modify lines in the dtsi file for MIUI
    sed -i 's/qcom,mdss-pan-physical-width-dimension = <147>;$/qcom,mdss-pan-physical-width-dimension = <1474>;/' arch/arm64/boot/dts/qcom/dsi-panel-k82-42-02-0a-video.dtsi
    sed -i 's/qcom,mdss-pan-physical-height-dimension = <236>;$/qcom,mdss-pan-physical-height-dimension = <2359>;/' arch/arm64/boot/dts/qcom/dsi-panel-k82-42-02-0a-video.dtsi
    zip_name="MIUI"
elif [ "$build_choice" = "2" ]; then
    # No modifications needed for AOSP build
    echo "AOSP build selected. No modifications needed."
    zip_name="AOSP"
else
    echo "Invalid choice. Exiting..."
    exit 1
fi

# Kernel-SU add

#curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# Build the kernel
echo "**** Kernel defconfig is set to $KERNEL_DEFCONFIG ****"
echo -e "$blue***********************************************"
echo "          BUILDING KERNEL          "
echo -e "***********************************************$nocol"
make $KERNEL_DEFCONFIG O=out CC=clang
make -j$(expr $(nproc --all) / 2) O=out \
                      CC=clang \
                      ARCH=arm64 \
                      CROSS_COMPILE=aarch64-linux-gnu- \
                      NM=llvm-nm \
                      OBJDUMP=llvm-objdump \
                      STRIP=llvm-strip

TIME="$(date "+%Y%m%d-%H%M%S")"
mkdir -p tmp
cp -fp $ZIMAGE_DIR/Image.gz tmp
cp -fp $ZIMAGE_DIR/dtbo.img tmp
cp -fp $ZIMAGE_DIR/dtb tmp
cp -rp ./anykernel/* tmp
cd tmp
7za a -mx9 tmp.zip *
cd ..
rm *.zip
cp -fp tmp/tmp.zip Rave-Nabu-${zip_name}-$TIME.zip
rm -rf tmp
echo $TIME

# Kernel-SU Remove

git checkout drivers/Makefile &>/dev/null
rm -rf KernelSU
rm -rf drivers/kernelsu

# Revert changes back to the original state
revert_changes
