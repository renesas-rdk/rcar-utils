#!/bin/sh
#
# Copyright (c) 2025-2026, Renesas Electronics Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#
SCRIPT_DIR=$(cd `dirname $0` && pwd)

cd ${SCRIPT_DIR}

has_modules() {
    "$1" -c 'import serial, colorama, tqdm' 2>/dev/null
}

# Ubuntu 24.04 refuses "pip install" outside a virtual environment, so use the
# system Python only when it already has the modules, and a local venv otherwise.
PYTHON=python3
if ! has_modules python3; then
    PYTHON=.venv/bin/python3
    if ! has_modules ${PYTHON}; then
        if ! python3 -m venv .venv; then
            echo "Error: cannot create a virtual environment. Install either of:"
            echo "    sudo apt-get install -y python3-venv"
            echo "    sudo apt-get install -y python3-serial python3-colorama python3-tqdm"
            exit 1
        fi
        ${PYTHON} -m pip install pyserial colorama tqdm || exit 1
    fi
fi
exec ${PYTHON} burn.py
