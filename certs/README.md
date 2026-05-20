# Corporate CA Certificates

Drop your internal / corporate root CA bundle here as a single
PEM-encoded file (concatenate multiple certs if needed):

```
certs/corporate-ca.crt
```

On `make up` (or `make secrets-apply`), if this file is present it is
loaded into Kubernetes as the `awx-custom-certs` secret with key
`bundle-ca.crt`, and the AWX CR is patched with
`bundle_cacert_secret: awx-custom-certs`. The AWX Operator then mounts
the bundle into the control-plane and execution-environment pods so
git/SCM, callbacks, and Ansible all trust the CA.

The CA path is configurable via `AWX_CA_BUNDLE_FILE` in `.env`.

`*.crt` and `*.pem` files in this directory are git-ignored.
