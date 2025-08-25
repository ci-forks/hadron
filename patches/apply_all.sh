#!/bin/bash
set -ex

PATCH_DIR=$1
SOURCE_DIR=$2
PATCH_FILES=${PATCH_FILES:-$(find $PATCH_DIR -name '*.patch')}

pushd $SOURCE_DIR
    # Apply all patches in the patches directory
    for patch in $PATCH_FILES; do
        patch -p1 < $patch
    done
popd