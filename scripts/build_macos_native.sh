#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Voice Coding"
PROJECT_PATH="$ROOT_DIR/apps/macos-native/VoiceCodingNative.xcodeproj"
APP_PATH="$ROOT_DIR/apps/macos-native/build/Release/$APP_NAME.app"
ZIP_PATH="$ROOT_DIR/apps/macos-native/build/Release/$APP_NAME.zip"

PYTHON_DIST_SOURCE="${VOICE_CODING_PYTHON_DIST:-$HOME/.local/share/uv/python/cpython-3.11.14-macos-aarch64-none}"
MODEL_SOURCE_DIR="$ROOT_DIR/models/SenseVoiceSmall"

BACKEND_ROOT="$APP_PATH/Contents/Resources/backend"
BACKEND_PYTHON_ROOT="$BACKEND_ROOT/python"
BACKEND_SOURCE_ROOT="$BACKEND_ROOT/src"
BACKEND_MODEL_ROOT="$BACKEND_ROOT/models/SenseVoiceSmall"

RUNTIME_PYTHON="$BACKEND_PYTHON_ROOT/bin/python3.11"
RUNTIME_DYLD_LIBRARY_PATH="$BACKEND_PYTHON_ROOT/lib"

copy_voice_coding_sources() {
  mkdir -p "$BACKEND_SOURCE_ROOT/voice_coding_app/backend"

  cp "$ROOT_DIR/apps/desktop/voice_coding_app/__init__.py" \
    "$BACKEND_SOURCE_ROOT/voice_coding_app/__init__.py"
  cp "$ROOT_DIR/apps/desktop/voice_coding_app/helper_service.py" \
    "$BACKEND_SOURCE_ROOT/voice_coding_app/helper_service.py"

  cp "$ROOT_DIR/apps/desktop/voice_coding_app/backend/__init__.py" \
    "$BACKEND_SOURCE_ROOT/voice_coding_app/backend/__init__.py"
  cp "$ROOT_DIR/apps/desktop/voice_coding_app/backend/audio_types.py" \
    "$BACKEND_SOURCE_ROOT/voice_coding_app/backend/audio_types.py"
  cp "$ROOT_DIR/apps/desktop/voice_coding_app/backend/config.py" \
    "$BACKEND_SOURCE_ROOT/voice_coding_app/backend/config.py"
  cp "$ROOT_DIR/apps/desktop/voice_coding_app/backend/paths.py" \
    "$BACKEND_SOURCE_ROOT/voice_coding_app/backend/paths.py"
  cp "$ROOT_DIR/apps/desktop/voice_coding_app/backend/text_processing.py" \
    "$BACKEND_SOURCE_ROOT/voice_coding_app/backend/text_processing.py"
  cp "$ROOT_DIR/apps/desktop/voice_coding_app/backend/transcriber.py" \
    "$BACKEND_SOURCE_ROOT/voice_coding_app/backend/transcriber.py"
}

copy_minimal_model() {
  if [ ! -f "$MODEL_SOURCE_DIR/model.pt" ]; then
    echo "Missing local SenseVoice model at: $MODEL_SOURCE_DIR" >&2
    exit 1
  fi

  mkdir -p "$BACKEND_MODEL_ROOT"

  cp "$MODEL_SOURCE_DIR/model.pt" "$BACKEND_MODEL_ROOT/model.pt"
  cp "$MODEL_SOURCE_DIR/config.yaml" "$BACKEND_MODEL_ROOT/config.yaml"
  cp "$MODEL_SOURCE_DIR/configuration.json" "$BACKEND_MODEL_ROOT/configuration.json"
  cp "$MODEL_SOURCE_DIR/am.mvn" "$BACKEND_MODEL_ROOT/am.mvn"
  cp "$MODEL_SOURCE_DIR/chn_jpn_yue_eng_ko_spectok.bpe.model" \
    "$BACKEND_MODEL_ROOT/chn_jpn_yue_eng_ko_spectok.bpe.model"
}

prune_embedded_python() {
  rm -rf \
    "$BACKEND_PYTHON_ROOT/include" \
    "$BACKEND_PYTHON_ROOT/share" \
    "$BACKEND_PYTHON_ROOT/lib/pkgconfig" \
    "$BACKEND_PYTHON_ROOT/lib/itcl4.3.5" \
    "$BACKEND_PYTHON_ROOT/lib/libtcl9.0.dylib" \
    "$BACKEND_PYTHON_ROOT/lib/libtcl9tk9.0.dylib" \
    "$BACKEND_PYTHON_ROOT/lib/tcl9" \
    "$BACKEND_PYTHON_ROOT/lib/tcl9.0" \
    "$BACKEND_PYTHON_ROOT/lib/tk9.0" \
    "$BACKEND_PYTHON_ROOT/lib/thread3.0.4" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/ensurepip"

  rm -f \
    "$BACKEND_PYTHON_ROOT/bin/2to3" \
    "$BACKEND_PYTHON_ROOT/bin/2to3-3.11" \
    "$BACKEND_PYTHON_ROOT/bin/f2py" \
    "$BACKEND_PYTHON_ROOT/bin/funasr" \
    "$BACKEND_PYTHON_ROOT/bin/funasr-export" \
    "$BACKEND_PYTHON_ROOT/bin/funasr-jsonl2scp" \
    "$BACKEND_PYTHON_ROOT/bin/funasr-scp2jsonl" \
    "$BACKEND_PYTHON_ROOT/bin/funasr-sensevoice2jsonl" \
    "$BACKEND_PYTHON_ROOT/bin/funasr-train" \
    "$BACKEND_PYTHON_ROOT/bin/funasr-train-ds" \
    "$BACKEND_PYTHON_ROOT/bin/hf" \
    "$BACKEND_PYTHON_ROOT/bin/httpx" \
    "$BACKEND_PYTHON_ROOT/bin/idle3" \
    "$BACKEND_PYTHON_ROOT/bin/idle3.11" \
    "$BACKEND_PYTHON_ROOT/bin/isympy" \
    "$BACKEND_PYTHON_ROOT/bin/jp.py" \
    "$BACKEND_PYTHON_ROOT/bin/jsonl2scp" \
    "$BACKEND_PYTHON_ROOT/bin/markdown-it" \
    "$BACKEND_PYTHON_ROOT/bin/modelscope" \
    "$BACKEND_PYTHON_ROOT/bin/ms" \
    "$BACKEND_PYTHON_ROOT/bin/normalizer" \
    "$BACKEND_PYTHON_ROOT/bin/numba" \
    "$BACKEND_PYTHON_ROOT/bin/numpy-config" \
    "$BACKEND_PYTHON_ROOT/bin/pip" \
    "$BACKEND_PYTHON_ROOT/bin/pip3" \
    "$BACKEND_PYTHON_ROOT/bin/pip3.11" \
    "$BACKEND_PYTHON_ROOT/bin/pydoc3" \
    "$BACKEND_PYTHON_ROOT/bin/pydoc3.11" \
    "$BACKEND_PYTHON_ROOT/bin/pygmentize" \
    "$BACKEND_PYTHON_ROOT/bin/pygrun" \
    "$BACKEND_PYTHON_ROOT/bin/python3-config" \
    "$BACKEND_PYTHON_ROOT/bin/python3.11-config" \
    "$BACKEND_PYTHON_ROOT/bin/scp2jsonl" \
    "$BACKEND_PYTHON_ROOT/bin/sensevoice2jsonl" \
    "$BACKEND_PYTHON_ROOT/bin/tiny-agents" \
    "$BACKEND_PYTHON_ROOT/bin/torchfrtrace" \
    "$BACKEND_PYTHON_ROOT/bin/torchrun" \
    "$BACKEND_PYTHON_ROOT/bin/tqdm" \
    "$BACKEND_PYTHON_ROOT/bin/typer"

  rm -rf \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/site-packages/pip" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/site-packages/pip-"*.dist-info \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/site-packages/setuptools" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/site-packages/setuptools-"*.dist-info \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/site-packages/pkg_resources" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/site-packages/_distutils_hack"
  rm -f "$BACKEND_PYTHON_ROOT/lib/python3.11/site-packages/distutils-precedence.pth"

  rm -rf \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/__phello__" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/__pycache__" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/idlelib" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/lib2to3" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/pydoc_data" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/tkinter" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/turtledemo" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/venv" \
    "$BACKEND_PYTHON_ROOT/lib/python3.11/site-packages/__pycache__"

  find "$BACKEND_PYTHON_ROOT" -name '__pycache__' -prune -exec rm -rf {} +
  find "$BACKEND_PYTHON_ROOT" -name '*.pyc' -delete
}

install_runtime_dependencies() {
  export DYLD_LIBRARY_PATH="$RUNTIME_DYLD_LIBRARY_PATH"

  "$RUNTIME_PYTHON" -m pip install --break-system-packages \
    "funasr>=1.1.18" \
    "huggingface-hub>=0.29.3" \
    "jieba>=0.42.1" \
    "numpy>=1.26.4" \
    "PyYAML>=6.0.2" \
    "torch>=2.6.0" \
    "torchaudio>=2.6.0"
}

echo "Building native Release app..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -target VoiceCodingNative \
  -configuration Release \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build CODE_SIGNING_ALLOWED=NO

if [ ! -d "$APP_PATH" ]; then
  echo "Missing built app: $APP_PATH" >&2
  exit 1
fi

if [ ! -d "$PYTHON_DIST_SOURCE" ]; then
  echo "Missing embedded Python source: $PYTHON_DIST_SOURCE" >&2
  exit 1
fi

echo "Preparing embedded backend..."
rm -rf "$BACKEND_ROOT" "$ZIP_PATH"
mkdir -p "$BACKEND_ROOT"
ditto "$PYTHON_DIST_SOURCE" "$BACKEND_PYTHON_ROOT"

copy_voice_coding_sources
install_runtime_dependencies
copy_minimal_model
prune_embedded_python

echo "Finalizing app metadata and signature..."
/usr/libexec/PlistBuddy -c "Delete VCWorkspaceRoot" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1 || true
codesign --force --deep --sign - --identifier local.voicecoding.native "$APP_PATH"
touch "$APP_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"

echo "Creating distributable zip..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Built app: $APP_PATH"
echo "Built zip: $ZIP_PATH"
du -sh "$APP_PATH" "$ZIP_PATH"
