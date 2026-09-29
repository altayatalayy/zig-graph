#!/bin/bash

conan remote add conancenter https://center.conan.io 2>/dev/null || true
conan remote update conancenter https://center.conan.io False

rm -rf install_linux/ build_linux/

conan install -if install_linux -pr:b x86_64_linux_gcc8_debug -pr:h x86_64_linux_gcc8_debug ./ && \
conan build -if install_linux -bf build_linux ./
