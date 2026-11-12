# Trust extra CA certificates (for example, a corporate TLS-intercepting proxy).
# Paste immediately after FROM, before the first apk add. Put *.crt, *.cer or *.pem
# certificates in the repository's top-level ca-certificates/; PEM and DER files
# are accepted. The XS launchers include that folder in the build context.
COPY ca-certificates/ /tmp/ca-certificates/
RUN mkdir -p /usr/local/share/ca-certificates && found=0 && \
    for f in /tmp/ca-certificates/*.crt /tmp/ca-certificates/*.cer /tmp/ca-certificates/*.pem; do \
        [ -f "$f" ] || continue; \
        found=$((found + 1)); \
        echo "Processing CA certificate file $(basename "$f")"; \
        crt="/usr/local/share/ca-certificates/$(basename "${f%.*}").crt"; \
        if grep -q -- '-----BEGIN CERTIFICATE-----' "$f"; then tr -d '\r' < "$f" > "$crt"; \
        else { echo '-----BEGIN CERTIFICATE-----'; base64 "$f" | tr -d '\n' | fold -w 64; echo; echo '-----END CERTIFICATE-----'; } > "$crt"; fi; \
        { echo; cat "$crt"; } >> /etc/ssl/certs/ca-certificates.crt; \
        echo "  trusting $(grep -c -- '-----BEGIN CERTIFICATE-----' "$crt") certificate(s) as $(basename "$crt")"; \
    done; \
    [ "$found" -gt 0 ] || echo "No additional certificate trust was requested"; \
    rm -rf /tmp/ca-certificates
RUN apk add --no-cache ca-certificates && update-ca-certificates
