"""
Pluggable Azure AI Vision analyzer.

Primary: Image Analysis 4.0 (`azure-ai-vision-imageanalysis`, GA).
Fallback: legacy Computer Vision 3.2 (`azure-cognitiveservices-vision-computervision`)
          for Brands/Color or caption in non-4.0 regions.

The analyzer takes a set of requested feature keys, intersects them with the
features the active API actually supports, calls the service once, and returns a
normalized result plus the transaction count (== number of features billed).

Normalized result schema (all keys always present):
{
  "caption":  {"text": str, "confidence": float} | None,
  "tags":     [{"name": str, "confidence": float}],
  "objects":  [{"name": str, "confidence": float, "box": {"x","y","w","h"}}],
  "people":   [{"confidence": float, "box": {...}}],
  "dense":    [{"text": str, "confidence": float, "box": {...}}],
  "ocr":      {"text": str, "lines": [{"text": str}]} | None,
  "brands":   [{"name": str, "confidence": float, "box": {...}}],
  "colors":   {"dominant": [str], "accent": str} | None,
  "meta":     {"width": int, "height": int},
  "applied":  [feature keys actually sent],
  "tx":       int
}
"""

import io
import logging

logger = logging.getLogger("analyzer")

# Canonical feature keys exposed to the UI.
ALL_FEATURES = ["tags", "objects", "caption", "people", "dense", "ocr", "brands", "color"]

# What each API version supports.
CAPS_V4 = {"tags", "objects", "caption", "people", "dense", "ocr"}
CAPS_V32 = {"tags", "objects", "caption", "brands", "color"}


class RateLimited(Exception):
    """Raised on HTTP 429 (free-tier quota / rate cap reached)."""


class AnalyzerError(Exception):
    pass


def _empty_result():
    return {
        "caption": None, "tags": [], "objects": [], "people": [],
        "dense": [], "ocr": None, "brands": [], "colors": None,
        "meta": {"width": 0, "height": 0}, "applied": [], "tx": 0,
    }


class Analyzer:
    def __init__(self, endpoint, key, api_version="v4"):
        self.endpoint = (endpoint or "").rstrip("/")
        self.key = key or ""
        self.api_version = api_version
        self.configured = bool(self.endpoint and self.key)
        self._v4 = None
        self._v32 = None
        if not self.configured:
            logger.warning("Azure credentials not set - analysis disabled.")

    # -- capability reporting (for the UI to gray out unsupported toggles) --
    def capabilities(self):
        return sorted(CAPS_V4 if self.api_version == "v4" else CAPS_V32)

    # -- lazy clients --
    def _client_v4(self):
        if self._v4 is None:
            from azure.ai.vision.imageanalysis import ImageAnalysisClient
            from azure.core.credentials import AzureKeyCredential
            self._v4 = ImageAnalysisClient(self.endpoint, AzureKeyCredential(self.key))
        return self._v4

    def _client_v32(self):
        if self._v32 is None:
            from azure.cognitiveservices.vision.computervision import ComputerVisionClient
            from msrest.authentication import CognitiveServicesCredentials
            self._v32 = ComputerVisionClient(self.endpoint, CognitiveServicesCredentials(self.key))
        return self._v32

    def analyze(self, jpeg_bytes, features):
        """Analyze JPEG bytes for the requested feature keys. Returns normalized dict."""
        if not self.configured:
            raise AnalyzerError("Azure credentials are not configured.")
        req = [f for f in features if f in ALL_FEATURES]
        if self.api_version == "v4":
            return self._analyze_v4(jpeg_bytes, req)
        return self._analyze_v32(jpeg_bytes, req)

    # ----------------------------------------------------------------- v4
    def _analyze_v4(self, jpeg_bytes, req):
        from azure.ai.vision.imageanalysis.models import VisualFeatures
        from azure.core.exceptions import HttpResponseError

        applied = [f for f in req if f in CAPS_V4]
        if not applied:
            r = _empty_result()
            r["applied"] = []
            return r

        fmap = {
            "tags": VisualFeatures.TAGS,
            "objects": VisualFeatures.OBJECTS,
            "caption": VisualFeatures.CAPTION,
            "people": VisualFeatures.PEOPLE,
            "dense": VisualFeatures.DENSE_CAPTIONS,
            "ocr": VisualFeatures.READ,
        }
        vfs = [fmap[f] for f in applied]
        want_caption = "caption" in applied or "dense" in applied
        try:
            kwargs = {"image_data": jpeg_bytes, "visual_features": vfs}
            if want_caption:
                kwargs["gender_neutral_caption"] = True
            result = self._client_v4().analyze(**kwargs)
        except HttpResponseError as e:
            if getattr(e, "status_code", None) == 429:
                raise RateLimited(str(e))
            raise AnalyzerError(getattr(getattr(e, "error", None), "message", None) or str(e))

        out = _empty_result()
        out["applied"] = applied
        out["tx"] = len(applied)
        if getattr(result, "metadata", None):
            out["meta"] = {"width": result.metadata.width, "height": result.metadata.height}

        if getattr(result, "caption", None) is not None:
            out["caption"] = {"text": result.caption.text,
                              "confidence": float(result.caption.confidence)}
        if getattr(result, "tags", None) is not None:
            out["tags"] = [{"name": t.name, "confidence": float(t.confidence)}
                           for t in result.tags.list]
        if getattr(result, "objects", None) is not None:
            for o in result.objects.list:
                name = o.tags[0].name if o.tags else "object"
                conf = float(o.tags[0].confidence) if o.tags else 0.0
                out["objects"].append({"name": name, "confidence": conf,
                                       "box": _bb(o.bounding_box)})
        if getattr(result, "people", None) is not None:
            out["people"] = [{"confidence": float(p.confidence), "box": _bb(p.bounding_box)}
                             for p in result.people.list]
        if getattr(result, "dense_captions", None) is not None:
            out["dense"] = [{"text": d.text, "confidence": float(d.confidence),
                             "box": _bb(d.bounding_box)} for d in result.dense_captions.list]
        if getattr(result, "read", None) is not None:
            lines = []
            for block in result.read.blocks:
                for ln in block.lines:
                    lines.append({"text": ln.text})
            out["ocr"] = {"text": "\n".join(l["text"] for l in lines), "lines": lines}
        return out

    # ---------------------------------------------------------------- v3.2
    def _analyze_v32(self, jpeg_bytes, req):
        from azure.cognitiveservices.vision.computervision.models import VisualFeatureTypes
        from msrest.exceptions import HttpOperationError

        applied = [f for f in req if f in CAPS_V32]
        if not applied:
            r = _empty_result()
            r["applied"] = []
            return r

        fmap = {
            "tags": VisualFeatureTypes.tags,
            "objects": VisualFeatureTypes.objects,
            "caption": VisualFeatureTypes.description,
            "brands": VisualFeatureTypes.brands,
            "color": VisualFeatureTypes.color,
        }
        vfs = [fmap[f] for f in applied]
        try:
            result = self._client_v32().analyze_image_in_stream(io.BytesIO(jpeg_bytes),
                                                                 visual_features=vfs)
        except HttpOperationError as e:
            code = getattr(getattr(e, "response", None), "status_code", None)
            if code == 429:
                raise RateLimited(str(e))
            raise AnalyzerError(str(e))

        out = _empty_result()
        out["applied"] = applied
        out["tx"] = len(applied)
        meta = getattr(result, "metadata", None)
        if meta:
            out["meta"] = {"width": meta.width, "height": meta.height}
        if getattr(result, "description", None) and result.description.captions:
            c = result.description.captions[0]
            out["caption"] = {"text": c.text, "confidence": float(c.confidence)}
        if getattr(result, "tags", None):
            out["tags"] = [{"name": t.name, "confidence": float(t.confidence)} for t in result.tags]
        if getattr(result, "objects", None):
            for o in result.objects:
                out["objects"].append({
                    "name": o.object_property, "confidence": float(o.confidence),
                    "box": {"x": o.rectangle.x, "y": o.rectangle.y,
                            "w": o.rectangle.w, "h": o.rectangle.h}})
        if getattr(result, "brands", None):
            for b in result.brands:
                out["brands"].append({
                    "name": b.name, "confidence": float(b.confidence),
                    "box": {"x": b.rectangle.x, "y": b.rectangle.y,
                            "w": b.rectangle.w, "h": b.rectangle.h}})
        if getattr(result, "color", None):
            out["colors"] = {"dominant": list(result.color.dominant_colors or []),
                             "accent": result.color.accent_color}
        return out


def _bb(box):
    """Normalize an Azure bounding_box (x,y,width,height) to {x,y,w,h}."""
    return {"x": int(box.x), "y": int(box.y), "w": int(box.width), "h": int(box.height)}
