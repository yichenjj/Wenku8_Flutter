#!/usr/bin/env bash
# Installs the built Linux bundle as a desktop application for the current
# user. Run `flutter build linux --release` first. The API runtime must be
# present in linux/proprietary/ before building (see docs/RELEASING.md and
# linux/patch_libcpp.py).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$root/build/linux/x64/release/bundle"
target="$HOME/.local/opt/wenku8_flutter"

if [[ ! -x "$bundle/wenku8_flutter" ]]; then
  echo "bundle not built; run: flutter build linux --release" >&2
  exit 1
fi

mkdir -p "$HOME/.local/opt" "$HOME/.local/share/applications"
rm -rf "$target"
cp -r "$bundle" "$target"

desktop="$HOME/.local/share/applications/wenku8_flutter.desktop"
cat > "$desktop" <<EOF
[Desktop Entry]
Type=Application
Name=轻小说文库
Comment=Wenku8 Flutter 桌面版
Exec=$target/wenku8_flutter
Icon=$target/data/flutter_assets/assets/branding/app-icon.png
Categories=Office;Viewer;
Terminal=false
EOF

update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
echo "installed: $target"
echo "launcher:  $desktop"
