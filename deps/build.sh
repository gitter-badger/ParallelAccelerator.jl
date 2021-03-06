#!/bin/bash

# Copyright (c) 2015, Intel Corporation
# All rights reserved.

# Redistribution and use in source and binary forms, with or without 
# modification, are permitted provided that the following conditions are met:
# - Redistributions of source code must retain the above copyright notice, 
#   this list of conditions and the following disclaimer.
# - Redistributions in binary form must reproduce the above copyright notice, 
#   this list of conditions and the following disclaimer in the documentation 
#   and/or other materials provided with the distribution.

# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF 
# THE POSSIBILITY OF SUCH DAMAGE.

CONF_FILE="generated/config.jl"
MKL_LIB=""
OPENBLAS_LIB=""

if [ -e "$CONF_FILE" ]
then
  rm -f "$CONF_FILE"
fi

if type "bcpp" >/dev/null 2>&1; then
    echo "use_bcpp = 1" >> "$CONF_FILE"
fi

# First check for existence of icpc; failing that, use gcc.
if type "icpc" >/dev/null 2>&1; then
    CC=icpc
    echo "backend_compiler = USE_ICC" >> "$CONF_FILE"
elif type "g++" >/dev/null 2>&1; then
    CC=g++
    echo "backend_compiler = USE_GCC" >> "$CONF_FILE"
else
    echo "You must have icpc or g++ installed to use ParallelAccelerator.";
    exit 1;
fi

syslibs=`echo "$LD_LIBRARY_PATH:$DYLD_LIBRARY_PATH"`
arr_libs=(${syslibs//:/ })

for lib in "${arr_libs[@]}"
do
    if echo "$lib" | grep -q "/mkl/"; then
        MKL_LIB=$lib
    fi
    if echo "$lib" | grep -q "OpenBLAS"; then
        OPENBLAS_LIB=$lib
    fi
done

if [ -z "$MKL_LIB" ]; then
    echo "MKL not detected (optional)"
fi

if [ -z "$OPENBLAS_LIB" ]; then
    echo "OpenBlas not detected (optional)"
fi

echo "mkl_lib = \"$MKL_LIB\"" >> "$CONF_FILE"
echo "openblas_lib = \"$OPENBLAS_LIB\"" >> "$CONF_FILE"


echo "Using $CC to build ParallelAccelerator array runtime.";
$CC -std=c++11 -fPIC -shared -o libj2carray.so.1.0 j2c-array.cpp
