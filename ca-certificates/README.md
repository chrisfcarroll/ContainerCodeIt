# Extra CA certificates

Put any extra CA certificates the image must trust here, as `*.crt`, `*.cer` or
`*.pem` files (PEM or DER). The typical case is a corporate proxy that intercepts
TLS: without its CA, the first `apk` fetch in the build fails with
`TLS: server certificate not trusted`.

code-it-build copies this folder into the build context, and the Dockerfile trusts
each certificate before the first `apk add`. Certificate files are git-ignored, so
they stay on your machine.

Include the whole chain up to and including the self-signed root CA. apk (OpenSSL)
does not accept a chain that ends at an intermediate CA, so with intermediates only
it still reports `server certificate not trusted`.

On Windows, the root is usually in the machine's Trusted Root store. For example, to
export a root named `PKI-ROOT-CA` (as DER, which the build also accepts):

```powershell
$root = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -eq 'CN=PKI-ROOT-CA'
Export-Certificate -Cert $root -FilePath ca-certificates\PKI-ROOT-CA.cer
```
