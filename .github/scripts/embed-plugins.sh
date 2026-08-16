#!/usr/bin/env bash
# Copy every built plugin into an app bundle, so a packaged VibeCare ships
# with its first-party plugins instead of an empty plugin list.
#
# Destination is <bundle>/Contents/Resources/plugins/<id>/, which is where
# vibecare-server looks: the server sits at Contents/Resources/vibecare-server
# and resolves `plugins` beside its own executable (resolvePluginsDirs in
# backend/cmd/server/main.go). Nothing here has to agree with the LaunchAgent
# plist on an install path, and the cask stays free to move the .app.
#
# The per-plugin layout MUST match the repo's exactly, because the manifest's
# `exec` is relative to the manifest's own directory: a plugin declaring
# `exec: ./dist/vision` needs its dist/ to arrive AS dist/. This mirrors the
# same two branches as `just install-plugins`; see that recipe for why the
# staged dist/ layout exists at all (short version: a directory holding an
# Info.plist beside a same-named executable reads as a flat bundle to
# codesign, and AMFI then SIGKILLs the plugin the instant core spawns it).
#
# Usage: embed-plugins.sh <app-bundle> [plugins-src-dir]

set -euo pipefail

APP_BUNDLE="${1:?App bundle path required}"
SRC="${2:-plugins}"
DEST="${APP_BUNDLE}/Contents/Resources/plugins"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: app bundle not found: $APP_BUNDLE" >&2
    exit 1
fi
if [ ! -d "$SRC" ]; then
    echo "Error: plugins source not found: $SRC" >&2
    exit 1
fi

echo "Embedding plugins from $SRC into $APP_BUNDLE"
rm -rf "$DEST"
mkdir -p "$DEST"

embedded=0
for dir in "$SRC"/*/; do
    id="$(basename "$dir")"
    [ -f "${dir}manifest.yaml" ] || continue

    mkdir -p "$DEST/$id"
    cp "${dir}manifest.yaml" "$DEST/$id/manifest.yaml"

    if [ -d "${dir}dist" ]; then
        # A plugin that stages its build output (every Swift plugin). Copy
        # dist/ AS dist/ so `exec: ./dist/<id>` resolves identically here.
        cp -R "${dir}dist" "$DEST/$id/dist"
    else
        # A plugin whose binary sits beside its manifest (todo).
        if [ ! -x "${dir}${id}" ]; then
            echo "Error: $id has neither dist/ nor an executable ${dir}${id}" >&2
            echo "       Did 'just build-plugins' run before this script?" >&2
            exit 1
        fi
        cp "${dir}${id}" "$DEST/$id/$id"
        # SwiftPM ships resources as a .bundle that the generated
        # Bundle.module accessor resolves relative to the executable, so it
        # has to travel with it. Copy the binary alone and the plugin's UI
        # serves a 500.
        for bundle in "${dir}"*.bundle; do
            [ -d "$bundle" ] || continue
            cp -R "$bundle" "$DEST/$id/$(basename "$bundle")"
        done
    fi

    echo "  ✓ $id"
    embedded=$((embedded + 1))
done

# A silently empty plugins directory produces a release that installs fine
# and does nothing — exactly the bug this script exists to prevent. Fail the
# build instead.
if [ "$embedded" -eq 0 ]; then
    echo "Error: no plugins embedded from $SRC" >&2
    exit 1
fi

echo "Embedded $embedded plugin(s) into $DEST"
