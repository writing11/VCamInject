#!/bin/sh
set +e

VCAM_DIR="/var/mobile/Library/VCam"
mkdir -p "$VCAM_DIR" >/dev/null 2>&1 || true
chmod 0777 "$VCAM_DIR" >/dev/null 2>&1 || true

JBROOT=""
if command -v jbroot >/dev/null 2>&1; then
    JBROOT="$(jbroot 2>/dev/null || true)"
fi
if [ -z "$JBROOT" ] && [ -d /var/jb ]; then
    JBROOT="/var/jb"
fi

for CANDIDATE in \
    "$JBROOT/usr/local/bin/vcamreceiverd" \
    /var/jb/usr/local/bin/vcamreceiverd \
    /usr/local/bin/vcamreceiverd \
    /private/preboot/*/jb-*/usr/local/bin/vcamreceiverd \
    /var/containers/Bundle/Application/.jbroot-*/usr/local/bin/vcamreceiverd
do
    if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ] && [ "$CANDIDATE" != "$0" ]; then
        exec "$CANDIDATE"
    fi
done

FOUND="$(find /var/jb /private/preboot /var/containers -path '*usr/local/bin/vcamreceiverd' -type f 2>/dev/null | head -n 1 || true)"
if [ -n "$FOUND" ] && [ -x "$FOUND" ]; then
    exec "$FOUND"
fi

echo "vcamreceiverd not found" >&2
exit 127
