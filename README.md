# rmpcd-listenbrainz

Scrobble your MPD listening history to [ListenBrainz](https://listenbrainz.org)
from [rmpcd](https://rmpc.mierak.dev/rmpcd/).

The plugin marks a track as "playing now" when it starts, then records a listen
once you have played half of it or four minutes, whichever comes first. If your
files carry MusicBrainz tags it submits the IDs too, so each listen links to the
right recording, release, and artists.

## Requirements

- [rmpcd](https://rmpc.mierak.dev/rmpcd/) running alongside MPD. The plugin uses
  rmpcd's Lua plugin API as of rmpc commit `8053d6c` (2026-07-21). rmpcd is
  pre-1.0 and its API can still change, so pin a known-good build if an update
  breaks the plugin.
- A ListenBrainz token from your [settings page](https://listenbrainz.org/settings/).
- Optional but recommended: a MusicBrainz-tagged library (for example one managed
  with [beets](https://beets.io)), so listens carry MBIDs.

## Install

Drop the plugin into your rmpcd plugins directory:

```sh
mkdir -p ~/.config/rmpcd/plugins
curl -o ~/.config/rmpcd/plugins/listenbrainz.lua \
  https://raw.githubusercontent.com/valentynkit/rmpcd-listenbrainz/main/listenbrainz.lua
```

Enable it in `~/.config/rmpcd/init.lua`:

```lua
rmpcd.install("plugins.listenbrainz"):setup({
    token = os.getenv("LISTENBRAINZ_TOKEN"),
})
```

Export the token before starting rmpcd, so it stays out of the config file:

```sh
export LISTENBRAINZ_TOKEN="your-token"
```

Restart rmpcd. That is all.

## Configuration

`setup` takes a table:

| Field | Default | Description |
|-------|---------|-------------|
| `token` | required | Your ListenBrainz user token. |
| `record_now_playing` | `true` | Send a "playing now" update when a track starts. |
| `url` | `https://api.listenbrainz.org` | API base, for a self-hosted server. |
| `enabled` | `true` | Whether scrobbling is on at startup. |

To hardcode the token instead of reading the environment, pass it as a literal
string in place of `os.getenv(...)`.

## Toggle at runtime

The plugin listens on the `rmpcd.listenbrainz` channel:

```sh
rmpc sendmessage rmpcd.listenbrainz toggle   # also: enable, disable
```

## How it works

- On each track change it sends `playing_now`, unless `record_now_playing` is
  `false`.
- It records a `single` listen once played time reaches
  `min(track_length / 2, 4 minutes)`. Paused time does not count, and each track
  is scrobbled at most once. Tracks shorter than five seconds, or of unknown
  length, are skipped.
- MusicBrainz IDs (`recording_mbid`, `release_mbid`, `release_group_mbid`,
  `artist_mbids`) are read from the file's tags when present.
- A submission that fails is retried from an in-memory queue. A listen the server
  rejects outright (HTTP 400 or 401) is dropped so it cannot block the queue.

## Limitations

- The retry queue is in memory, so a backlog is lost if rmpcd restarts while
  ListenBrainz is unreachable.
- rmpcd does not expose HTTP response headers, so a rate-limited submission is
  retried on the next playback event rather than after the server's reset window.

## Development

`test.lua` is a self-contained offline test. It stubs rmpcd's globals and a
clock, then exercises the JSON encoder, the request payloads, and the play-time
state machine (thresholds, pause, resume, stop, and retry):

```sh
luajit test.lua   # or: lua test.lua
```

## Credits

Modeled on rmpcd's built-in Last.fm plugin. The JSON encoder is purpose-built for
the submit payload, since rmpcd exposes no encoder and no `package.path`.

## License

[BSD-3-Clause](LICENSE).
