## Install

Grab **`anipocket-@VERSION@-arm64-v8a.apk`** — that is the right build for
essentially every phone made in the last decade. Take the `universal` one if you
are not sure; it is bigger but runs everywhere.

Android will ask you to allow installing from an unknown source. There is no Play
Store build: the app has no accounts and no server, and nothing to sell.

## Verify what you downloaded

Every APK here is signed with the project release key **and** carries a Sigstore
provenance attestation binding it to commit [`@SHA@`](https://github.com/@REPO@/commit/@SHA@)
and to the workflow run that produced it. Nothing was built or uploaded by hand.

```bash
# the build really came from this repository, at this commit
gh attestation verify anipocket-@VERSION@-arm64-v8a.apk -R @REPO@

# the bytes match what the workflow published
sha256sum -c SHA256SUMS.txt --ignore-missing
```
