#!/bin/sh
set -eu
# Run on a Linux host with Docker. Archives remain outside public web roots.
if [ "$#" -ne 2 ]; then
  echo 'Usage: crawl.sh URL COLLECTION' >&2
  exit 2
fi
url=$1
collection=$2
case "$url" in http://*|https://*) ;; *) echo 'HTTP or HTTPS URL required' >&2; exit 2;; esac
case "$collection" in ''|*[!a-zA-Z0-9_-]*) echo 'Collection must contain letters, digits, underscores or hyphens' >&2; exit 2;; esac
service_root=${CRAWLER_ROOT:-/opt/offline-browser}
archive_root="$service_root/crawls"
behavior_root=${CRAWLER_BEHAVIOR_ROOT:-"$service_root/behaviors"}
image=${CRAWLER_IMAGE:-webrecorder/browsertrix-crawler:1.15.0@sha256:9a0df32c1a61eb12de5d0faa19a63fbef8924257a5e4e1496803594527a69a31}
if [ -e "$archive_root/collections/$collection" ]; then
  echo 'Collection already exists; choose a new name to preserve its data' >&2
  exit 2
fi
mkdir -p "$archive_root"
exec docker run -d --name "offline-browser-$collection" --shm-size=1g \
  -v "$archive_root:/crawls" \
  -v "$behavior_root:/behaviors:ro" \
  "$image" \
  crawl --url "$url" --scopeType host --depth 2 --workers 1 --collection "$collection" \
  --generateWACZ --behaviors autoscroll autofetch siteSpecific \
  --selectLinks 'a[href]' 'iframe[src]->@src' 'frame[src]->@src' 'embed[src]->@src' \
  --customBehaviors /behaviors/collect-embedded-frames.js \
  --screenshot view fullPageFinal --saveState always --saveStateInterval 60 --lang de
