# Troubleshooting

[English](../en/troubleshooting.md) · [Русский](../ru/troubleshooting.md)

Error messages in this app are written to be actionable — the screen prints the
error text as-is, and every message names what actually failed. This page maps the
common ones onto a fix.

---

## Search returns an error instead of results

> The source answered with an error — most likely its bot protection kicked in.
> A mirror, a proxy or a different source in settings usually helps.

The catalog site (AnimeGO more often than Animedia) responded with a non-2xx
status. Things to try, in order:

1. **Settings → AnimeGO mirror** — enter an alternative domain, for example
   `animego.me`. The main domain is the one that tends to sit behind Cloudflare.
2. **Settings → Source** — switch to Animedia. Fewer dubs, but a completely
   different site.
3. **Settings → HTTP proxy** — `host:port`. Note that only HTTP proxies work;
   dio does not support SOCKS on Android.
4. **Settings → Clear the catalog cache** — if you just changed one of the above
   and still see the old failure.

Changing the source, the mirror, the address or the proxy rebuilds the HTTP client
and clears the caches automatically, so a retry after any of these is a genuine
fresh attempt.

## "Could not find …" when opening a title or an episode

> Could not find the video parameters — the player has most likely changed its
> markup.

This is an `ExtractionError`: the response arrived but the parser did not
recognise it. A site or a player changed its HTML.

* As a user: pick a different dub chip on the title page, or a different player
  for the same dub. It is rare for all of them to break at once.
* As a developer: the fix is a regular expression in the matching
  `lib/anime/players/*.dart` or `lib/anime/sources/*.dart`. Save the new response
  into `test/fixtures/`, add the assertion, then fix the pattern. Running
  `dart run tool/smoke.dart "<some title>"` shows whether the break is at the
  source or at a player.

## "This player is not supported yet"

The catalog offered an embed from a player that has no parser. Pick another chip
in **Dub and player**. Supported: Aniboom, Kodik, CVH, Sibnet, Animedia,
AniLibria, VK Video.

## "The player is temporarily unavailable. Try a different dub."

A `ServiceError` from the player itself. Usually transient — a different dub is
the quickest route around it. The catalog caches resolved links for four minutes,
so retrying the same one immediately will return the same failure until the cache
expires or you clear it in settings.

## Video will not start: "The player could not open the track"

ExoPlayer rejected the stream. Try:

1. The **HD** icon in the player → a different quality or container. If the
   current track is HLS, an MP4 variant of the same episode often plays.
2. The dub icon → another player.
3. Lower **Maximum quality** in settings, if the device cannot handle the top one.

## An episode fails to download

Read the reason under the failed task on the **Downloads** screen.

| Reason | What is going on |
|---|---|
| Split audio track | Aniboom serves fMP4 with audio separate. It cannot be merged without re-encoding, so the app resolves the same episode through another player instead — if it queued anyway, pick Kodik, CVH or Sibnet explicitly on the title page |
| Encrypted playlist (`#EXT-X-KEY`) | Encrypted HLS can be watched but not saved. Pick another dub or player |
| A network or service error | Use **Resume** in the task menu. The link is re-resolved from scratch on every resume, so an expired URL is not the problem |

## Downloads stop when I leave the app

That is by design: no background service is started. Running tasks become
*paused* and continue from where they stopped the next time the app opens — mp4
by byte range, HLS from the next segment. Keep the app in the foreground for an
uninterrupted run.

## Downloaded episodes disappeared

Files live in the app's internal folder, which needs no storage permission but is
deleted together with the app. Clearing the app's data removes them too. On the
**Downloads** screen a task whose file is gone reports "File not found — it may
have been deleted".

## Playback position or list entries are not saved

Everything lives in SQLite on the device — there is no sync and no account, so
there is nothing to log into and nothing to restore from. Clearing app data or
reinstalling wipes the list, the ratings and the progress along with it.

Progress is written every 15 seconds and again when you leave the player; killing
the app from the task switcher mid-episode can cost the last few seconds.

## An episode is not marked as watched

An episode counts as watched past 85 % of its duration by default. Adjust it under
**Settings → Count an episode as watched**, anywhere from 50 % to 98 %.

## Posters do not load

Poster images are fetched from the catalog site and cached. If the site is blocked
for you, the app still works — only the artwork is missing. A proxy or a mirror
fixes it.

## Nothing works at all after changing settings

Use **Settings → Clear the catalog cache**. It drops cached search results,
episode lists and video links. If you are still stuck, the live check is the
fastest way to tell whether the problem is the phone or the site:

```bash
dart run tool/smoke.dart "Наруто"
dart run tool/smoke.dart "Наруто" --source animedia
```
