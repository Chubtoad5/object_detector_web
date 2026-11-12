"""The login FFmpeg's RTSP client sends for a camera URL, read the way libavformat reads it (spec 21, O8).

av_url_split: the userinfo runs from after "://" to the last @ before the first / ? or #, and is copied, still
encoded, into auth[128], so only its first 127 bytes are kept. Then ff_urldecode (%XX only; + stays +), and the user
ends at the first ':'. Basic auth sends user:password whole, which the camera splits there too.

As a command: ffmpeg_login.py <url> checks the URL against WANT_USER and WANT_PASSWORD from the environment, and exits
1 with what differs (never the values) when it isn't exact.
"""
import os
import sys
from urllib.parse import unquote_to_bytes

FFMPEG_AUTH_MAX = 127


def login(url):
    """(user, password, length of the encoded userinfo) as FFmpeg logs in, or None for a URL with no userinfo."""
    i = url.find("://")
    if i < 0:
        return None
    rest = url[i + 3:]
    end = len(rest)
    for ch in "/?#":
        j = rest.find(ch)
        if 0 <= j < end:
            end = j
    at = rest.rfind("@", 0, end)
    if at < 0:
        return None
    auth = rest[:at]
    raw = unquote_to_bytes(auth[:FFMPEG_AUTH_MAX])
    user, _, password = raw.partition(b":")
    return (user.decode("utf-8", "surrogateescape"), password.decode("utf-8", "surrogateescape"), len(auth))


def check(url, want_user, want_password):
    """'' when FFmpeg logs in with exactly this user and password, else what differs."""
    got = login(url)
    if got is None:
        return "the URL has no user or password in it"
    user, password, n = got
    problems = []
    if n > FFMPEG_AUTH_MAX:
        problems.append("the encoded userinfo is %d bytes, over FFmpeg's %d" % (n, FFMPEG_AUTH_MAX))
    if user != want_user:
        problems.append("FFmpeg sends another user")
    if password != want_password:
        problems.append("FFmpeg sends another password")
    return "; ".join(problems)


if __name__ == "__main__":
    problem = check(sys.argv[1], os.environ["WANT_USER"], os.environ["WANT_PASSWORD"])
    if problem:
        print(problem)
        sys.exit(1)
