#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$DIR"

NINJA="/Library/Frameworks/Python.framework/Versions/3.14/bin/ninja"

echo "Building passes and transforms for iOS arm64..."
cd toolchains/llvm-ios-build
$NINJA LLVMPasses LLVMTransformUtils LLVMScalarOpts LLVMInstCombine LLVMLinker LLVMAnalysis LLVMCore LLVMSupport LLVMBitReader LLVMBitWriter LLVMBinaryFormat

cd "$DIR"

# Also check stub for dxmt_d3d9_unix_call_wow64_funcs
cat << 'C_EOF' > /tmp/dxmt_stubs.c
#include <stdint.h>
const void *dxmt_d3d9_unix_call_wow64_funcs[] = { 0 };
C_EOF
xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -c /tmp/dxmt_stubs.c -o /tmp/dxmt_stubs.o

rm -rf /tmp/libdxmt_work
mkdir -p /tmp/libdxmt_work
cd /tmp/libdxmt_work

echo "Extracting previous libdxmt_combined.a..."
ar -x "$DIR/app/Madeira/libdxmt_combined.a"

echo "Extracting newly built LLVM libs..."
for lib in LLVMPasses LLVMTransformUtils LLVMScalarOpts LLVMInstCombine LLVMLinker; do
    if [ -f "$DIR/toolchains/llvm-ios-build/lib/lib${lib}.a" ]; then
        echo "Extracting lib${lib}.a"
        mkdir -p "$lib"
        cd "$lib"
        ar -x "$DIR/toolchains/llvm-ios-build/lib/lib${lib}.a"
        cd ..
        cp "$lib"/*.o .
    fi
done

cp /tmp/dxmt_stubs.o .

echo "Recreating app/Madeira/libdxmt_combined.a..."
libtool -static -o "$DIR/app/Madeira/libdxmt_combined.a" *.o

cd "$DIR"
rm -rf /tmp/libdxmt_work
echo "Done updating libdxmt_combined.a!"
