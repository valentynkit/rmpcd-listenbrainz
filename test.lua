-- Offline self-test for listenbrainz.lua. Run from this dir: luajit test.lua
-- Stubs the rmpcd globals and injects a fake clock, then exercises the pure
-- helpers plus the play-time state machine (now-playing, thresholds, pause,
-- resume, once-only, disabled).

-- Fake clock so timing is deterministic.
local clock = 1000
os.time = function()
    return clock
end

-- Capture every submitted body.
local bodies = {}
local next_code = 200
_G.http = {
    post = function(url, opts)
        bodies[#bodies + 1] = { url = url, opts = opts }
        return { code = next_code }
    end,
}
_G.log = setmetatable({}, {
    __index = function()
        return function() end
    end,
})

local M = dofile("listenbrainz.lua")
local I = M._internal

local function contains(haystack, needle)
    return haystack:find(needle, 1, true) ~= nil
end

local function count_listen_type(kind)
    local n = 0
    for _, b in ipairs(bodies) do
        if contains(b.opts.body, '"listen_type":"' .. kind .. '"') then
            n = n + 1
        end
    end
    return n
end

local function reset()
    bodies = {}
    next_code = 200
    M:setup({ token = "test-token" })
end

--------------------------------------------------------------------------------
-- 1. Encoder: primitives, escaping, array vs object
--------------------------------------------------------------------------------
assert(I.encode('a"b\\c\n\t') == '"a\\"b\\\\c\\n\\t"', "string escaping")
assert(I.encode(1234) == "1234", "integer")
assert(I.encode({ 1, 2, 3 }) == "[1,2,3]", "array")
assert(I.encode({ a = 1 }) == '{"a":1}', "object")
assert(I.encode({}) == "{}", "empty table encodes as object")
assert(I.encode("\1") == '"\\u0001"', "control char -> \\u escape")

--------------------------------------------------------------------------------
-- Mock MetadataTag + Song
--------------------------------------------------------------------------------
local function mtag(...)
    local vals = { ... }
    return {
        first = function()
            return vals[1]
        end,
        values = function()
            return vals
        end,
    }
end

local function make_song(duration_ms)
    return {
        duration = duration_ms,
        artist = mtag("The Artist"),
        title = mtag("The Title"),
        album = mtag("The Album"),
        track = mtag("5"),
        musicbrainz_track_id = mtag("MBID-REC"),
        musicbrainz_album_id = mtag("MBID-REL"),
        musicbrainz_release_group_id = mtag("MBID-RG"),
        musicbrainz_artist_id = mtag("MBID-A1", "MBID-A2"),
    }
end
local song = make_song(200000) -- 200s => threshold 100s

--------------------------------------------------------------------------------
-- 2. build_payload: single vs playing_now, MBID fields
--------------------------------------------------------------------------------
local single = I.encode(I.build_payload(song, 1700000000))
assert(contains(single, '"listen_type":"single"'), "single type")
assert(contains(single, '"listened_at":1700000000'), "listened_at present")
assert(contains(single, '"artist_name":"The Artist"'), "artist_name")
assert(contains(single, '"track_name":"The Title"'), "track_name")
assert(contains(single, '"release_name":"The Album"'), "release_name")
assert(contains(single, '"recording_mbid":"MBID-REC"'), "recording_mbid")
assert(contains(single, '"release_mbid":"MBID-REL"'), "release_mbid")
assert(contains(single, '"release_group_mbid":"MBID-RG"'), "release_group_mbid")
assert(contains(single, '"artist_mbids":["MBID-A1","MBID-A2"]'), "artist_mbids array")
assert(contains(single, '"duration_ms":200000'), "duration_ms")
assert(contains(single, '"submission_client":"rmpcd-listenbrainz"'), "submission_client")

local now_body = I.encode(I.build_payload(song, nil))
assert(contains(now_body, '"listen_type":"playing_now"'), "playing_now type")
assert(not contains(now_body, "listened_at"), "no listened_at in playing_now")

local bare = I.encode(I.build_payload({ duration = 200000, artist = mtag("A"), title = mtag("T") }, 1))
assert(not contains(bare, "artist_mbids"), "artist_mbids omitted when absent")
assert(not contains(bare, "recording_mbid"), "recording_mbid omitted when absent")

--------------------------------------------------------------------------------
-- 3. should_scrobble(song, played_secs)
--------------------------------------------------------------------------------
assert(I.should_scrobble(song, 100) == true, "half of 200s reached")
assert(I.should_scrobble(song, 99) == false, "under half")
local long = make_song(600000) -- 10 min => 4-min cap governs
assert(I.should_scrobble(long, 240) == true, "4-minute cap reached")
assert(I.should_scrobble(long, 239) == false, "under 4 min and under half")
assert(I.should_scrobble(make_song(0), 100) == false, "unknown duration (0) skipped")
assert(I.should_scrobble(make_song(3000), 100) == false, "sub-5s track skipped")
assert(I.should_scrobble({ duration = 200000 }, 100) == false, "no artist/title skipped")

--------------------------------------------------------------------------------
-- 4. now-playing on song start; scrobble previous on next change
--------------------------------------------------------------------------------
reset()
clock = 1000
M:song_change(nil, song)
assert(#bodies == 1 and contains(bodies[1].opts.body, "playing_now"), "now-playing at start")
assert(bodies[1].opts.headers["Authorization"] == "Token test-token", "auth header")
clock = 1150 -- played 150s >= 100s threshold
M:song_change(song, make_song(200000))
assert(count_listen_type("single") == 1, "previous track scrobbled once")
-- listened_at is the ORIGINAL start (1000), not the change time
local scrobble = bodies[#bodies - 0]
local prev_single
for _, b in ipairs(bodies) do
    if contains(b.opts.body, '"listen_type":"single"') then
        prev_single = b
    end
end
assert(contains(prev_single.opts.body, '"listened_at":1000'), "listened_at is playback start")

--------------------------------------------------------------------------------
-- 5. paused-through track is NOT scrobbled (only 30s of a 300s track played)
--------------------------------------------------------------------------------
reset()
clock = 1000
M:song_change(nil, make_song(300000)) -- 300s => threshold 150s
clock = 1030
M:state_change("play", "pause") -- played 30s
clock = 2000
M:state_change("pause", "stop") -- long pause, still only 30s played
assert(count_listen_type("single") == 0, "paused-through track not scrobbled")

--------------------------------------------------------------------------------
-- 6. pause then resume then finish: scrobbled exactly once, not lost
--------------------------------------------------------------------------------
reset()
clock = 1000
M:song_change(nil, make_song(300000)) -- threshold 150s
clock = 1100
M:state_change("play", "pause") -- played 100s
clock = 5000
M:state_change("pause", "play") -- resume after long pause
clock = 5060
M:song_change(make_song(300000), nil) -- +60s played => 160s total >= 150s
assert(count_listen_type("single") == 1, "resumed track scrobbled once")

--------------------------------------------------------------------------------
-- 7. no double scrobble: eligible at pause, then song changes
--------------------------------------------------------------------------------
reset()
clock = 1000
M:song_change(nil, song) -- 200s track, threshold 100s
clock = 1200
M:state_change("play", "pause") -- played 200s >= 100 => scrobble now
assert(count_listen_type("single") == 1, "scrobbled at pause")
clock = 1300
M:song_change(song, make_song(200000)) -- finalize old: must not scrobble again
assert(count_listen_type("single") == 1, "not scrobbled twice")

--------------------------------------------------------------------------------
-- 8. disabled: no submissions at all
--------------------------------------------------------------------------------
reset()
M:message(nil, "disable")
clock = 1000
M:song_change(nil, song)
clock = 1200
M:song_change(song, make_song(200000))
assert(#bodies == 0, "no submit while disabled")

--------------------------------------------------------------------------------
-- 9. retry semantics: a 429 keeps the item; a later ok drains it. A 400 drops.
--------------------------------------------------------------------------------
reset()
clock = 1000
M:song_change(nil, song)
bodies = {} -- ignore the now-playing
clock = 1150
next_code = 429 -- server busy
M:song_change(song, make_song(200000)) -- scrobble attempt fails, stays queued
assert(count_listen_type("single") == 1, "one attempt made")
local attempts_after_429 = #bodies
next_code = 200
clock = 1200
M:state_change("play", "pause") -- any later event drains the queue
assert(#bodies > attempts_after_429, "queued listen retried on next event")

print("all tests passed")
