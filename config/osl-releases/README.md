# OSL Release Manifests

Each OSL pre-release should have one local manifest JSON file:

- Path: `config/osl-releases/<version>.json`
- Template: `config/osl-releases/example.json`

Recommended flow:

```bash
cp config/osl-releases/example.json config/osl-releases/1.39.0.CR1.json
# Edit with values from the pre-release email
```

`prepare-osl-internal.sh` reads this file to:

- select IIB by OCP minor version
- mirror required source images (amd64 by default)
- build a rewritten internal logic-only catalog image
- create `CatalogSource/osl-custom-catalog` and wait for it to be READY
- write `.env.osl` with `OSL_*` exports

## Schema

```json
{
  "version": "1.39.0.CR1",
  "iib": {
    "4.17": "registry-proxy.engineering.redhat.com/rh-osbs/iib:123456",
    "4.18": "registry-proxy.engineering.redhat.com/rh-osbs/iib:123457"
  },
  "images": [
    {
      "source": "registry-proxy.engineering.redhat.com/rh-osbs/openshift-serverless-1-logic-rhel9-operator@sha256:<digest>",
      "name": "logic-rhel9-operator"
    }
  ]
}
```

Notes:

- `version` is the full release version string (e.g. `1.39.0.CR1`). The short
  major.minor (e.g. `1.39`) is derived automatically for `OSL_LOGIC_CSV`.
- `iib` must include the current cluster's `major.minor` version.
- `images[].source` should be a full digest reference from the release email.
- `iib[*]` should also be digest-pinned where possible (`...@sha256:...`).
- `images[].name` is a short identifier used as the internal registry repo name.
- Set `ENFORCE_DIGEST_PINNING=1` to fail fast when non-digest references are present.
- Manifest files are ignored by git by default (`config/osl-releases/*.json`), except `example.json`.
