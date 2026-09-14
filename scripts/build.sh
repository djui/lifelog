#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

swift build --configuration release --product icloud-exporter
build_dir=$(swift build --configuration release --show-bin-path)
resource_bundle=ICloudExporter_ICloudExporterCore.bundle

if [ ! -d "$build_dir/$resource_bundle" ]; then
  echo "Build failed to produce the required SwiftPM resource bundle: $resource_bundle" >&2
  exit 1
fi

app="$project_dir/dist/icloud-exporter.app"
executable_link="$project_dir/dist/icloud-exporter"
contents="$app/Contents"
macos="$contents/MacOS"
resources="$contents/Resources"

rm -rf "$app" "$executable_link"
mkdir -p "$macos" "$resources"
cp "$build_dir/icloud-exporter" "$macos/icloud-exporter"
chmod 755 "$macos/icloud-exporter"
ditto "$build_dir/$resource_bundle" "$resources/$resource_bundle"
cp "$project_dir/Support/Info.plist" "$contents/Info.plist"

identity="-"
if identities=$(security find-identity -v -p codesigning 2>/dev/null); then
  developer_id=$(printf '%s\n' "$identities" | awk -F'"' '/Developer ID Application:/{print $2; exit}')
  apple_dev=$(printf '%s\n' "$identities" | awk -F'"' '/Apple Development:/{print $2; exit}')
  if [ -n "${developer_id:-}" ]; then
    identity=$developer_id
  elif [ -n "${apple_dev:-}" ]; then
    identity=$apple_dev
  fi
fi

# The SwiftPM resource directory is not a codesignable bundle; it is sealed as
# app resources. A certificate-backed signature keeps a stable TCC identity
# across rebuilds; ad-hoc signatures still change with the binary contents.
if [ "$identity" = "-" ]; then
  codesign --force --sign - --identifier com.djui.icloud-exporter "$app"
else
  codesign --force --sign "$identity" --identifier com.djui.icloud-exporter \
    --timestamp=none "$app"
fi

ln -s "icloud-exporter.app/Contents/MacOS/icloud-exporter" "$executable_link"

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$lsregister" ]; then
  "$lsregister" -f "$app" >/dev/null 2>&1 || true
fi

echo "Packaged exporter: $app"
if [ "$identity" = "-" ]; then
  echo "Signed ad-hoc. Scheduled runs may re-prompt after each rebuild."
else
  echo "Signed as: $identity"
fi
