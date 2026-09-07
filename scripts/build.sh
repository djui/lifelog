#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

swift build --configuration release --product icloud-exporter
build_dir=$(swift build --configuration release --show-bin-path)
destination="$project_dir/dist/icloud-exporter"
resource_bundle=ICloudExporter_ICloudExporterCore.bundle

if [ ! -d "$build_dir/$resource_bundle" ]; then
  echo "Build failed to produce the required SwiftPM resource bundle: $resource_bundle" >&2
  exit 1
fi

mkdir -p "$destination"
cp "$build_dir/icloud-exporter" "$destination/icloud-exporter"
ditto "$build_dir/$resource_bundle" "$destination/$resource_bundle"

echo "Packaged exporter: $destination/icloud-exporter"
