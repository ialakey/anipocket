# Security

## Reporting a vulnerability

Please use [private vulnerability reporting](https://github.com/ialakey/anipocket/security/advisories/new)
rather than a public issue. I will confirm receipt and, if the report holds, fix
it and credit you in the release notes unless you would rather stay anonymous.

## What the app does and does not do

Worth stating plainly, because it rules out whole classes of vulnerability:

* **No server, no accounts, no telemetry.** Nothing is transmitted anywhere
  except to the catalog sites and video players, and only to fetch what the app
  is about to show you.
* **No credentials.** There is nothing to log into, so there is nothing to leak.
* **Everything is local.** The watchlist, ratings, progress and downloaded files
  live in the app's private storage and are deleted with the app.
* **No extra permissions.** Downloads go to internal app storage precisely so
  that no storage permission is needed.

What that leaves as genuinely interesting: the parsers in `lib/anime/`, which
consume untrusted HTML and JSON from third-party sites, and the downloader, which
writes files from untrusted URLs. Reports about those are very welcome.

## Verifying a release

Every APK published under [Releases](https://github.com/ialakey/anipocket/releases)
is built by [`.github/workflows/release.yml`](.github/workflows/release.yml) on a
GitHub runner, signed with the project release key, and carries a Sigstore
provenance attestation tying it to the exact commit and workflow run that
produced it. Nothing is ever built or uploaded from a laptop.

```bash
gh attestation verify anipocket-1.0.0-arm64-v8a.apk -R ialakey/anipocket
sha256sum -c SHA256SUMS.txt --ignore-missing
```

If an APK claiming to be from this project fails that check, it did not come from
here. The signing key exists only as a repository secret and on the maintainer's
machine; it is not in this repository and never passes through a pull request.
