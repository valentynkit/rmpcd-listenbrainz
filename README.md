# rmpcd-listenbrainz

A [rmpcd](https://rmpc.mierak.dev/rmpcd/) plugin that scrobbles your MPD plays to
[ListenBrainz](https://listenbrainz.org).

It sends a "playing now" notification when a track starts and records a listen
once you have played half the track or four minutes, whichever comes first. When
your files are tagged with MusicBrainz IDs it submits them, so listens link to the
correct recordings.

## Requirements

- rmpcd running as your MPD companion daemon. This plugin targets the rmpcd Lua
  plugin API as of rmpc commit `8053d6c` (2026-07-21). rmpcd is pre-1.0 and its
  API can change; pin a known-good build if an update breaks the plugin.
- A ListenBrainz user token from <https://listenbrainz.org/settings/>.
- MusicBrainz tags on your library are optional but recommended (beets writes
  them by default).

## Install

Copy `listenbrainz.lua` into your rmpcd plugins directory:

```sh
mkdir -p ~/.config/rmpcd/plugins
cp listenbrainz.lua ~/.config/rmpcd/plugins/
```

Then install it in `~/.config/rmpcd/init.lua`:

```lua
rmpcd.install("plugins.listenbrainz"):setup({
    token = "<your listenbrainz user token>",
    -- record_now_playing = true,             -- optional, default true
    -- url = "https://api.listenbrainz.org",  -- optional, for a self-hosted server
    -- enabled = true,                        -- optional, default true
})
```

Restart rmpcd.

## Toggle at runtime

The plugin listens on the `rmpcd.listenbrainz` channel:

```sh
rmpc sendmessage rmpcd.listenbrainz toggle    # or: enable / disable
```

## How it works

- On track change it sends `playing_now` (unless `record_now_playing = false`).
- It records a `single` listen once *played* time (paused time excluded) reaches
  `min(track_length / 2, 4 minutes)`. Tracks shorter than 5 seconds or of unknown
  length are skipped, following ListenBrainz guidance. Pausing and resuming keeps
  the count accurate, and each track is scrobbled at most once.
- It sends `recording_mbid`, `release_mbid`, `release_group_mbid` and
  `artist_mbids` from your `MUSICBRAINZ_*` tags when present.
- Failed submissions are retried from an in-memory queue. A permanently rejected
  listen (HTTP 400/401) is dropped so it cannot block the queue.

## Limitations

- The retry queue lives in memory, so a backlog is lost if rmpcd restarts while
  ListenBrainz is unreachable.
- rmpcd's HTTP API does not expose response headers, so a rejected submission is
  retried on the next playback event rather than after the server's
  `X-RateLimit-Reset-In` window.
- Changing tracks while playback is paused is treated as if the new track were
  playing until the next state change (a rare edge; ordinary pause/resume is
  accounted for accurately).

## Development

`test.lua` is an offline self-test that stubs the rmpcd globals:

```sh
luajit test.lua    # or: lua test.lua
```

## Credit

Modeled on rmpcd's built-in Last.fm plugin. The JSON encoder is purpose-built for
the submit payload, since rmpcd exposes no encoder and no `package.path`.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
