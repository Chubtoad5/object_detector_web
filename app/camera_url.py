"""Camera URLs that carry a user and a password (spec 21, O8 and O13).

deploy.sh (for RTSP_USER / CAMERA_<N>_USER and their passwords) and the app (for the Add Camera form) both build the
URL here, so the two always agree. Standard library only, and Python 3.6 or later: deploy.sh runs it with the host's
python3.

build_url(url, user, password, names): the URL with "user:password@" put in after "scheme://". Each is
percent-encoded byte by byte: every byte except the unreserved A-Z a-z 0-9 - . _ ~ becomes %XX. FFmpeg decodes the
userinfo before it logs in to the camera, under Basic and Digest auth alike, so the camera gets the password exactly
as typed. With no user and no password the URL is returned as given, so a URL with the login inside it works as
before. A value that can't work raises CredentialError, whose message names the setting but never shows its value.

mask_url(url): the URL with its password shown as ***, for the UI and the API.
"""

UNRESERVED = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
# FFmpeg's RTSP client copies the URL's userinfo, still encoded, into a 128-byte buffer (libavformat/rtsp.c,
# auth[128]): 127 bytes and the end. A longer one is cut off with no error, and the camera refuses the login.
RTSP_USERINFO_MAX = 127
PASSWORD_MAX = 128
MASK = "***"


class CredentialError(ValueError):
    """A camera user or password that can't work. The message names the setting, never the value."""


def encode(value):
    """value percent-encoded: every byte of its UTF-8 form but the unreserved characters becomes %XX."""
    data = value.encode("utf-8", "surrogateescape")
    return "".join(chr(b) if b in UNRESERVED else "%%%02X" % b for b in data)


def _has_control(value):
    return any(ord(c) < 32 or ord(c) == 127 for c in value)


def _split(url):
    """(start of the authority, end of the authority, position of the userinfo's @ or -1), as FFmpeg reads a URL:
    the authority runs from after "://" to the first / ? or #, and the userinfo ends at its last @."""
    i = url.find("://")
    if i < 0:
        return -1, -1, -1
    start = i + 3
    end = len(url)
    for ch in "/?#":
        j = url.find(ch, start)
        if 0 <= j < end:
            end = j
    return start, end, url.rfind("@", start, end)


def build_url(url, user, password, names=("RTSP_URL", "RTSP_USER", "RTSP_PASSWORD")):
    url_name, user_name, password_name = names
    user = user or ""
    password = password or ""
    if not user and not password:
        return url
    if _has_control(user):
        raise CredentialError("%s can't contain a control character, such as a tab or a newline." % user_name)
    if _has_control(password):
        raise CredentialError("%s can't contain a control character, such as a tab or a newline." % password_name)
    if not user:
        raise CredentialError("%s needs %s: a camera password goes with a user name." % (password_name, user_name))
    if ":" in user:
        raise CredentialError("%s can't contain ':', because a camera login splits the user from the password there."
                              % user_name)
    if len(password) > PASSWORD_MAX:
        raise CredentialError("%s is longer than %d characters." % (password_name, PASSWORD_MAX))
    start, _, at = _split(url)
    if start < 0:
        raise CredentialError("%s needs to start with rtsp:// (or another scheme) to carry %s and %s."
                              % (url_name, user_name, password_name))
    if at >= 0:
        raise CredentialError("%s already has a user and password in it. Give them in the URL or as %s and %s, "
                              "not both." % (url_name, user_name, password_name))
    userinfo = encode(user) + ":" + encode(password)
    if url[:start].lower().startswith("rtsp") and len(userinfo) > RTSP_USERINFO_MAX:
        raise CredentialError("%s and %s take %d bytes once percent-encoded (user:password), and FFmpeg reads at most "
                              "%d for an RTSP camera. Use a shorter password: each symbol or space takes 3 bytes."
                              % (user_name, password_name, len(userinfo), RTSP_USERINFO_MAX))
    return url[:start] + userinfo + "@" + url[start:]


def mask_url(url):
    """url with the password in its userinfo replaced by ***. A user with no password is shown as it is."""
    if not isinstance(url, str):
        return url
    start, _, at = _split(url)
    if start < 0:
        return url
    if at < 0:
        # A password typed into the URL with a raw / ? or # in it (which never connects) leaves its @ past the first
        # / ? or #: hide up to the last @ instead, so the password is never shown.
        at = url.rfind("@", start)
        if at < 0:
            return url
    userinfo = url[start:at]
    colon = userinfo.find(":")
    if colon < 0:
        return url
    return url[:start] + userinfo[:colon] + ":" + MASK + url[at:]
