"""Emby routes for the disposable Apple HTTPS fixture."""

import json
import re
from threading import Lock
from urllib.parse import parse_qs, urlsplit
from uuid import UUID


TOKEN = "fixture-emby-token"
USER_ID = "fixture-emby-user"
LIBRARY_ID = "fixture-emby-library"
DIRECT_ITEM = "native-direct"
HLS_ITEM = "native-hls"
MOVIES = [
    {"Id": DIRECT_ITEM, "Name": "Fixture Emby Direct", "Type": "Movie", "OfficialRating": "G"},
    {"Id": HLS_ITEM, "Name": "Fixture Emby HLS", "Type": "Movie", "OfficialRating": "G"},
]
SUBTITLE = {"Type": "Subtitle", "Index": 3, "IsTextSubtitleStream": True, "IsExternal": True, "Language": "eng"}
IDENTITY = re.compile(r'Emby Client="MediaVault", Device="Apple TV", DeviceId="([^"]+)", Version="[^"]+"')


def device_id(value):
    try:
        return str(UUID(value)) if value else None
    except ValueError:
        return None


class EmbyRoutes:
    _emby_lock = Lock()

    def serve_emby(self):
        parts = urlsplit(self.path)
        query = parse_qs(parts.query, keep_blank_values=True)
        identity = IDENTITY.fullmatch(self.headers.get("Authorization", ""))
        source_device = device_id(identity.group(1)) if identity else None
        if not source_device or TOKEN in self.path or any(
            "token" in name.lower() or "apikey" in re.sub(r"[^a-z]", "", name.lower())
            or TOKEN in name or any(TOKEN in value for value in values)
            for name, values in query.items()
        ):
            self.send_body(401)
            return

        route = parts.path.removeprefix("/emby/")
        if self.command == "POST" and route == "Users/AuthenticateByName":
            if self.headers.get("X-Emby-Token") is not None or self.emby_json_body() != {
                "Username": "fixture-emby", "Pw": "fixture-only",
            }:
                self.send_body(401)
                return
            self.send_json({"AccessToken": TOKEN, "User": {"Id": USER_ID, "Name": "Fixture Emby"}})
            return
        if self.headers.get("X-Emby-Token") != TOKEN:
            self.send_body(401)
            return

        if self.command == "GET" and route == f"Users/{USER_ID}/Views":
            self.send_json({"Items": [{"Id": LIBRARY_ID, "Name": "Fixture Emby Movies",
                                       "Type": "CollectionFolder", "CollectionType": "movies"}]})
        elif self.command == "GET" and route == f"Users/{USER_ID}/Items":
            self.emby_catalog(query)
        elif match := re.fullmatch(r"Items/(native-direct|native-hls)/PlaybackInfo", route):
            self.emby_playback_info(match[1], query, source_device)
        elif self.command == "GET" and route == f"Videos/{DIRECT_ITEM}/stream":
            scope = {"Static": ["true"], "MediaSourceId": [f"{DIRECT_ITEM}-source"],
                     "PlaySessionId": [f"{DIRECT_ITEM}-session"]}
            if any(query.get(key) != value for key, value in scope.items()) or (
                device_id(self.emby_query_value(query, "DeviceId")) != source_device
            ) or self.headers.get("Accept-Encoding") != "identity":
                self.send_body(400)
                return
            self.send_range()
        elif self.command == "GET" and re.fullmatch(r"Videos/native-hls/(master\.m3u8|variant\.m3u8|segment\d+\.ts)", route):
            if not self.emby_owns_encoding(query, source_device) or self.headers.get("Accept-Encoding") != "identity":
                self.send_body(403)
                return
            self.send_hls(parts.path)
        elif self.command == "GET" and re.fullmatch(r"Videos/(native-direct/native-direct-source|native-hls/native-hls-source)/Subtitles/3/Stream\.srt", route):
            self.send_body(200, b"1\n00:00:07,000 --> 00:00:11,000\nFixture Emby caption.\n",
                           [("Content-Type", "application/x-subrip")])
        elif self.command == "POST" and route == "Sessions/Logout":
            self.send_body(204)
        elif self.command == "POST" and route in {"Sessions/Playing", "Sessions/Playing/Progress", "Sessions/Playing/Stopped"}:
            self.emby_report(route)
        elif self.command == "DELETE" and route == "Videos/ActiveEncodings":
            with self._emby_lock:
                encodings = self.emby_encodings
                encoder = device_id(self.emby_query_value(query, "DeviceId"))
                owned = query.get("PlaySessionId") == [f"{HLS_ITEM}-session"] and encodings.get(encoder) == source_device
                if owned:
                    del encodings[encoder]
            self.send_body(204 if owned else 403)
        else:
            self.send_body(404)

    def emby_catalog(self, query):
        if query.get("ParentId") != [LIBRARY_ID] or query.get("Recursive") != ["true"] or (
            query.get("EnableUserData") != ["false"] or query.get("Limit") != ["100"]
        ):
            self.send_body(400)
            return
        offset = self.emby_query_value(query, "StartIndex")
        if offset not in {"0", "1"}:
            self.send_body(400)
            return
        self.send_json({"Items": [MOVIES[int(offset)]], "TotalRecordCount": len(MOVIES)})

    def emby_playback_info(self, item, query, source_device):
        if query.get("UserId") != [USER_ID]:
            self.send_body(400)
            return
        session = f"{item}-session"
        source = {"Id": f"{item}-source", "Container": "mp4", "MediaStreams": [{"Type": "Video", "Codec": "h264"}, SUBTITLE]}
        if self.command == "GET":
            source["SupportsDirectPlay"] = item == DIRECT_ITEM
            self.send_json({"PlaySessionId": session, "MediaSources": [source]})
        elif self.command == "POST" and item == HLS_ITEM:
            encoder = device_id(self.emby_query_value(query, "DeviceId"))
            body = self.emby_json_body() or {}
            profile = body.get("DeviceProfile", {})
            profiles = profile.get("TranscodingProfiles", []) if isinstance(profile, dict) else []
            if not encoder or encoder == source_device or body.get("UserId") != USER_ID or (
                body.get("EnableDirectPlay") is not False or body.get("EnableDirectStream") is not False
                or body.get("EnableTranscoding") is not True
                or not isinstance(profiles, list)
                or not any(isinstance(value, dict) and value.get("Protocol") == "hls"
                           and value.get("VideoCodec") == "h264" and value.get("AudioCodec") == "aac"
                           for value in profiles)
            ):
                self.send_body(400)
                return
            with self._emby_lock:
                self.emby_encodings[encoder] = source_device
            source["TranscodingUrl"] = f"/emby/Videos/{item}/master.m3u8?api_key={TOKEN}"
            self.send_json({"PlaySessionId": session, "MediaSources": [source]})
        else:
            self.send_body(404)

    def emby_report(self, route):
        data = self.emby_json_body() or {}
        item = data.get("ItemId")
        methods = {DIRECT_ITEM: "DirectPlay", HLS_ITEM: "Transcode"}
        ticks = data.get("PositionTicks")
        if item not in (DIRECT_ITEM, HLS_ITEM) or data.get("MediaSourceId") != f"{item}-source" or (
            data.get("PlaySessionId") != f"{item}-session" or type(ticks) is not int or ticks < 0
        ):
            self.send_body(400)
            return
        if route != "Sessions/Playing/Stopped" and (
            data.get("PlayMethod") != methods[item] or data.get("CanSeek") is not True or type(data.get("IsPaused")) is not bool
        ):
            self.send_body(400)
            return
        self.send_body(204)

    @property
    def emby_encodings(self):
        return self.server.__dict__.setdefault("emby_encodings", {})

    def emby_owns_encoding(self, query, source_device):
        encoder = device_id(self.emby_query_value(query, "DeviceId"))
        with self._emby_lock:
            return bool(encoder and self.emby_encodings.get(encoder) == source_device
                        and query.get("PlaySessionId") == [f"{HLS_ITEM}-session"]
                        and query.get("MediaSourceId") == [f"{HLS_ITEM}-source"])

    @staticmethod
    def emby_query_value(query, key):
        values = query.get(key, [])
        return values[0] if len(values) == 1 else None

    def emby_json_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 65536:
                return None
            value = json.loads(self.rfile.read(length))
            return value if isinstance(value, dict) else None
        except ValueError:
            return None
