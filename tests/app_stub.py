"""Loads app/app.py for the unit tests, with stand-ins for Flask, OpenCV, NumPy, gevent and the Azure analyzer, which
the test container doesn't have (spec 21, O8 and O13). camera_url is the real one. A test calls a route and reads what
it returns and what it stored.

    import app_stub
    app = app_stub.load("/tmp/x")                     # APP_DIR; cameras.json lives there
    body, code = app_stub.call(app, "POST", app.api_cameras, {"url": "rtsp://h/s", "user": "u", "password": "p"})
"""
import importlib.util
import os
import sys
import types

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class _Request:
    method = "GET"
    body = None

    def get_json(self, force=False, silent=False):
        return self.body


class _Flask:
    def __init__(self, name):
        self.routes = {}

    def route(self, rule, methods=("GET",)):
        def deco(f):
            self.routes[rule] = f
            return f
        return deco

    def run(self, *a, **k):
        pass


def _module(name, **attrs):
    m = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(m, k, v)
    return m


def load(app_dir):
    os.environ["APP_DIR"] = app_dir
    os.environ["STATE_DIR"] = os.path.join(app_dir, "state")
    os.environ["PERSIST_DIR"] = os.path.join(app_dir, "persist")

    class Analyzer:
        configured = False

        def __init__(self, *a, **k):
            pass

        def capabilities(self):
            return []

    sys.modules["flask"] = _module("flask", Flask=_Flask, request=_Request(), jsonify=lambda *a, **k: a[0] if a else k,
                                   Response=lambda *a, **k: None, send_from_directory=lambda *a, **k: None)
    sys.modules["analyzer"] = _module("analyzer", Analyzer=Analyzer, ALL_FEATURES=[],
                                      RateLimited=type("RateLimited", (Exception,), {}),
                                      AnalyzerError=type("AnalyzerError", (Exception,), {}))
    sys.modules["gevent"] = _module("gevent", spawn=lambda *a, **k: None, sleep=lambda *a: None)
    sys.modules["cv2"] = _module("cv2")
    sys.modules["numpy"] = _module("numpy")
    sys.path.insert(0, os.path.join(REPO, "app"))
    spec = importlib.util.spec_from_file_location("odw_app", os.path.join(REPO, "app", "app.py"))
    app = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(app)
    return app


def call(app, method, view, body=None, *args):
    """(the JSON body, the status code) of a route called with this method and JSON body."""
    app.request.method = method
    app.request.body = body
    r = view(*args)
    return r if isinstance(r, tuple) else (r, 200)
