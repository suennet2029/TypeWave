#!/bin/sh
codesign --force --deep --sign - --identifier local.voicecoding.native "${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
touch "${TARGET_BUILD_DIR}/${WRAPPER_NAME}" "${TARGET_BUILD_DIR}/${WRAPPER_NAME}/Contents/MacOS/${EXECUTABLE_NAME}"

