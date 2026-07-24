# Changelog

## [Unreleased]

### Added

- Initial ListenBrainz scrobbler: `playing_now` on track start, a `single` listen
  once played time (paused time excluded) reaches the half-track / 4-minute
  threshold, MusicBrainz IDs from tags, an in-memory retry queue with
  status-branched retry, and runtime enable/disable/toggle on the
  `rmpcd.listenbrainz` channel.
