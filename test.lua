-- Offline self-test for listenbrainz.lua. Run from this dir: luajit test.lua
-- Stubs the rmpcd globals, then exercises the pure helpers + one integration path.

local captured = {}
_G.http = {
    post = function(url, opts)
        captured.url = url
        captured.opts = opts
        return { code = 200 }
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

-- encode: primitives, escaping, array vs object
assert(I.encode('a"b\\c\n\t') == '"a\\"b\\\\c\\n\\t"', "string escaping")
assert(I.encode(1234) == "1234", "integer")
assert(I.encode({ 1, 2, 3 }) == "[1,2,3]", "array")
assert(I.encode({ a = 1 }) == '{"a":1}', "object")
assert(I.encode({}) == "{}", "empty table encodes as object")
assert(I.encode("\1") == '"\\u0001"', "control char -> \\u escape")

-- mock MetadataTag + Song
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
local song = {
    duration = 200000, -- 200s in ms
    artist = mtag("The Artist"),
    title = mtag("The Title"),
    album = mtag("The Album"),
    track = mtag("5"),
    musicbrainz_track_id = mtag("MBID-REC"),
    musicbrainz_album_id = mtag("MBID-REL"),
    musicbrainz_release_group_id = mtag("MBID-RG"),
    musicbrainz_artist_id = mtag("MBID-A1", "MBID-A2"),
}

-- build_payload: single listen
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

-- build_payload: playing_now omits listened_at
local now_body = I.encode(I.build_payload(song, nil))
assert(contains(now_body, '"listen_type":"playing_now"'), "playing_now type")
assert(not contains(now_body, "listened_at"), "no listened_at in playing_now")

-- MBIDs omitted when absent (no empty arrays / keys)
local bare = { duration = 200000, artist = mtag("A"), title = mtag("T") }
local bare_body = I.encode(I.build_payload(bare, 1))
assert(not contains(bare_body, "artist_mbids"), "artist_mbids omitted when absent")
assert(not contains(bare_body, "recording_mbid"), "recording_mbid omitted when absent")

-- should_scrobble
assert(I.should_scrobble(100, 200, song) == true, "half of 200s reached at 100s")
assert(I.should_scrobble(100, 150, song) == false, "50s is under half")
local long = { duration = 600000, artist = mtag("A"), title = mtag("T") } -- 10 min
assert(I.should_scrobble(0, 240, long) == true, "4-minute cap reached")
assert(I.should_scrobble(0, 239, long) == false, "under 4 min and under half")
assert(
    I.should_scrobble(0, 100, { duration = 0, artist = mtag("A"), title = mtag("T") }) == false,
    "unknown duration (0) skipped"
)
assert(
    I.should_scrobble(0, 100, { duration = 3000, artist = mtag("A"), title = mtag("T") }) == false,
    "sub-5s track skipped"
)
assert(I.should_scrobble(0, 100, { duration = 200000 }) == false, "no artist/title skipped")

-- integration: now-playing at start, scrobble the previous track on next change
M:setup({ token = "test-token" })
M:song_change(nil, song)
assert(captured.opts ~= nil, "http.post called for now-playing")
assert(captured.opts.headers["Authorization"] == "Token test-token", "auth header")
assert(contains(captured.opts.body, '"listen_type":"playing_now"'), "now-playing body")

captured.opts = nil
M.song_start = os.time() - 300 -- pretend the previous track played for 5 minutes
M:song_change(song, song)
assert(captured.opts ~= nil, "http.post called to scrobble the previous track")
assert(contains(captured.opts.body, '"listen_type":"single"'), "scrobble is a single listen")

-- disabled: no submissions
M:message(nil, "disable")
captured.opts = nil
M:song_change(song, song)
assert(captured.opts == nil, "no submit while disabled")

print("all tests passed")
