---@diagnostic disable: undefined-global
-- ListenBrainz scrobbler plugin for rmpcd.
--
-- Submits "playing now" on track start and a "single" listen once the track has
-- been *played* (paused time excluded) for half its length or 4 minutes,
-- whichever is lower. Sends MusicBrainz IDs when the file is tagged. Modeled on
-- rmpcd's built-in Last.fm plugin; auth is a single ListenBrainz user token.
--
-- rmpcd exposes no JSON encoder and no package.path, so a tiny purpose-built
-- encoder is embedded below (the submit payload is a fixed shape).

local SUBMISSION_CLIENT = "rmpcd-listenbrainz"
local CLIENT_VERSION = "0.1.0"
local MEDIA_PLAYER = "mpd"
local MIN_TRACK_MS = 5000 -- ignore tracks shorter than 5s or of unknown length
local MAX_SCROBBLE_SECS = 4 * 60 -- ListenBrainz caps the threshold at 4 minutes

--------------------------------------------------------------------------------
-- JSON encoding (minimal, encode-only). Works on Lua 5.1 (LuaJIT) .. 5.5.
--------------------------------------------------------------------------------

local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function escape_str(s)
    return (s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
    end))
end

-- ponytail: a table with a [1] element encodes as a JSON array, otherwise as an
-- object. Safe only because this plugin never emits an empty array (MBID arrays
-- are omitted when absent), so an empty table always means "{}".
local function encode(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        return string.format("%d", math.floor(v))
    elseif t == "string" then
        return '"' .. escape_str(v) .. '"'
    elseif t == "table" then
        local parts = {}
        if #v > 0 then
            for i = 1, #v do
                parts[i] = encode(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, val in pairs(v) do
            parts[#parts + 1] = '"' .. escape_str(tostring(k)) .. '":' .. encode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    error("listenbrainz: cannot encode value of type " .. t)
end

--------------------------------------------------------------------------------
-- Deque (in-memory scrobble queue). Copied from the built-in Last.fm plugin.
--------------------------------------------------------------------------------

local Deque = {}
Deque.__index = Deque

function Deque.new()
    return setmetatable({ first = 0, last = -1 }, Deque)
end

function Deque:push_right(value)
    self.last = self.last + 1
    self[self.last] = value
end

function Deque:pop_left()
    if self.first > self.last then
        return nil
    end
    local value = self[self.first]
    self[self.first] = nil
    self.first = self.first + 1
    return value
end

function Deque:peek_left()
    if self.first > self.last then
        return nil
    end
    return self[self.first]
end

--------------------------------------------------------------------------------
-- Payload + submission
--------------------------------------------------------------------------------

local function tag(t)
    return t ~= nil and t:first() or nil
end

-- Build a submit-listens request body. listened_at nil => "playing_now".
local function build_payload(song, listened_at)
    local info = {
        submission_client = SUBMISSION_CLIENT,
        submission_client_version = CLIENT_VERSION,
        media_player = MEDIA_PLAYER,
    }
    if song.duration and song.duration > 0 then
        info.duration_ms = song.duration
    end
    if song.track ~= nil then
        info.tracknumber = song.track:first()
    end
    if song.musicbrainz_track_id ~= nil then
        info.recording_mbid = song.musicbrainz_track_id:first()
    end
    if song.musicbrainz_album_id ~= nil then
        info.release_mbid = song.musicbrainz_album_id:first()
    end
    if song.musicbrainz_release_group_id ~= nil then
        info.release_group_mbid = song.musicbrainz_release_group_id:first()
    end
    if song.musicbrainz_artist_id ~= nil then
        info.artist_mbids = song.musicbrainz_artist_id:values()
    end

    local meta = {
        artist_name = tag(song.artist),
        track_name = tag(song.title),
        additional_info = info,
    }
    if song.album ~= nil then
        meta.release_name = song.album:first()
    end

    local listen = { track_metadata = meta }
    if listened_at ~= nil then
        listen.listened_at = listened_at
    end

    return {
        listen_type = listened_at ~= nil and "single" or "playing_now",
        payload = { listen },
    }
end

-- Returns "ok" | "drop" | "retry".
local function submit(self, body)
    local resp = http.post(self.url .. "/1/submit-listens", {
        headers = {
            ["Authorization"] = "Token " .. self.token,
            ["Content-Type"] = "application/json",
        },
        body = body,
    })

    local code = resp.code
    if code == 200 then
        return "ok"
    elseif code == 400 or code == 401 then
        log.error("ListenBrainz rejected a listen (HTTP " .. tostring(code) .. "), dropping it")
        return "drop"
    end
    -- 429, 5xx, or nil (network failure) => keep it and retry on the next event.
    log.warn("ListenBrainz submit failed (HTTP " .. tostring(code) .. "), will retry")
    return "retry"
end

local function scrobblable(song)
    return song ~= nil and song.artist ~= nil and song.title ~= nil
end

local function send_now_playing(self, song)
    if not scrobblable(song) then
        return
    end
    submit(self, encode(build_payload(song, nil)))
end

local function process_queue(self)
    while true do
        local item = self.queue:peek_left()
        if item == nil then
            break
        end
        local result = submit(self, encode(build_payload(item.song, item.timestamp)))
        if result == "retry" then
            break
        end
        self.queue:pop_left() -- "ok" or "drop"
    end
end

local function should_scrobble(song, played_secs)
    if not scrobblable(song) then
        return false
    end
    local duration_ms = song.duration or 0
    if duration_ms < MIN_TRACK_MS then
        return false
    end
    return played_secs >= MAX_SCROBBLE_SECS or played_secs >= (duration_ms / 1000) / 2
end

--------------------------------------------------------------------------------
-- Play-time accounting. Tracks seconds actually played (paused time excluded)
-- so a paused-through track is not scrobbled and a resumed one is not lost.
--------------------------------------------------------------------------------

-- Seconds of the current song played so far, including the in-progress segment.
local function played_secs(self, now)
    local played = self.played
    if self.playing_since ~= nil then
        played = played + (now - self.playing_since)
    end
    return played
end

-- Freeze the play clock (on pause/stop): fold the open segment into `played`.
local function pause_clock(self, now)
    if self.playing_since ~= nil then
        self.played = self.played + (now - self.playing_since)
        self.playing_since = nil
    end
end

-- Queue the current song once if it has passed the threshold.
local function try_scrobble(self, now)
    if self.scrobbled or not self.enabled or self.current_song == nil then
        return
    end
    if should_scrobble(self.current_song, played_secs(self, now)) then
        self.queue:push_right({ song = self.current_song, timestamp = self.started_at })
        self.scrobbled = true
    end
end

--------------------------------------------------------------------------------
-- Plugin
--------------------------------------------------------------------------------

local M = {}

M.setup = function(self, args)
    local base_url = args.url or "https://api.listenbrainz.org"
    self.token = args.token
    self.url = (base_url:gsub("/+$", ""))
    self.record_now_playing = args.record_now_playing ~= false
    self.enabled = args.enabled ~= false
    self.queue = Deque.new()
    self.current_song = nil
    self.started_at = nil -- epoch seconds of first playback of the current song
    self.played = 0 -- accumulated played seconds, paused segments excluded
    self.playing_since = nil -- epoch of the open play segment, nil while paused
    self.scrobbled = false -- current song already queued?

    if self.token == nil or self.token == "" then
        log.error("ListenBrainz plugin has no token configured, disabling it")
        self.enabled = false
    end
end

M.song_change = function(self, _old, new)
    local now = os.time()

    -- Finalize the outgoing song, then start the incoming one. Assume the new
    -- song is playing; state_change corrects it if playback is actually paused.
    try_scrobble(self, now)

    self.current_song = new
    self.started_at = new ~= nil and now or nil
    self.played = 0
    self.playing_since = new ~= nil and now or nil
    self.scrobbled = false

    if self.enabled and new ~= nil and self.record_now_playing then
        send_now_playing(self, new)
    end

    process_queue(self)
end

M.state_change = function(self, _old, new)
    local now = os.time()

    if new == "play" then
        if self.current_song ~= nil then
            if self.playing_since == nil then
                self.playing_since = now
            end
            if self.started_at == nil then
                self.started_at = now
            end
        end
    else -- pause or stop: freeze the clock, scrobble if already eligible
        pause_clock(self, now)
        try_scrobble(self, now)
    end

    process_queue(self)
end

M.subscribed_channels = { "rmpcd.listenbrainz" }

M.message = function(self, _channel, message)
    if message == "enable" then
        self.enabled = true
    elseif message == "disable" then
        self.enabled = false
    elseif message == "toggle" then
        self.enabled = not self.enabled
    else
        return
    end
    log.info("ListenBrainz plugin " .. (self.enabled and "enabled" or "disabled"))
end

-- ponytail: pure helpers exposed for the offline self-test (test.lua); ignored by rmpcd.
M._internal = {
    encode = encode,
    escape_str = escape_str,
    build_payload = build_payload,
    should_scrobble = should_scrobble,
}

return M
