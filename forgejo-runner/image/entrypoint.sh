#!/bin/sh
# Trust the homelab step-ca root next to the public roots without root
# privileges: build a combined bundle in /tmp and point Go (the runner),
# git and Node at it. Then run the given command (daemon or register).
set -eu
bundle=/tmp/ca-bundle.pem
cat /etc/ssl/certs/ca-certificates.crt > "$bundle"
if [ -r /etc/ssl/homelab/root_ca.crt ]; then
  cat /etc/ssl/homelab/root_ca.crt >> "$bundle"
fi
export SSL_CERT_FILE="$bundle" GIT_SSL_CAINFO="$bundle" NODE_EXTRA_CA_CERTS="$bundle"
exec "$@"
