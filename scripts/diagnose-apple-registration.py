import base64
import ctypes
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import re
import ssl
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import uuid4

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None

opener = build_opener(NoRedirect)
runtime = Path(sys.argv[1]).resolve()
constants = Path(".build-dependencies/AnisetteKit/Sources/Constants.swift").read_text()
identifier = uuid4()

def constant(name):
    return re.search(r'let ' + name + r'\s*= "([^"]+)"', constants).group(1)

headers = {
    "X-Mme-Device-Id": str(identifier).upper(),
    "User-Agent": constant("defaultUserAgent"),
    "X-Mme-Client-Info": constant("defaultClientInfo"),
    "X-Apple-I-MD-RINFO": constant("defaultRoutingInfo"),
    "X-Apple-I-MD-LU": constant("defaultLocalUserID"),
    "X-Apple-I-SRL-NO": constant("defaultSerialNumber"),
    "X-Apple-Locale": constant("defaultLocale"),
    "X-Apple-I-TimeZone": constant("defaultTimeZone"),
    "Content-Type": "text/x-xml-plist",
    "Accept": "*/*",
}

def request(stage, url, payload=None):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.hostname != "gsa.apple.com":
        raise SystemExit(f"{stage}: expected Apple GrandSlam HTTPS endpoint")
    headers["X-Apple-I-Client-Time"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = None if payload is None else plistlib.dumps({"Header": {}, "Request": payload})
    try:
        response = opener.open(Request(url, data=body, headers=headers), timeout=15)
    except HTTPError as error:
        maybe_proxy = error.read(500).lower()
        reason = " (gateway could not connect upstream)" if b"upstream connect error" in maybe_proxy else ""
        raise SystemExit(f"{stage}: HTTP {error.code}{reason}") from None
    except URLError as error:
        if isinstance(error.reason, ssl.SSLCertVerificationError):
            raise SystemExit(f"{stage}: TLS verification failed ({error.reason.verify_message})") from None
        raise SystemExit(f"{stage}: network error {type(error.reason).__name__}") from None
    with response:
        print(f"{stage}: HTTP {response.status}", flush=True)
        data = plistlib.loads(response.read(1048576))
        routing = response.headers.get("X-Apple-I-MD-RINFO") or data.get("Response", {}).get("routing-info")
        if routing:
            headers["X-Apple-I-MD-RINFO"] = str(routing)
        return data

urls = request("Lookup", "https://gsa.apple.com/grandslam/GsService2/lookup")["urls"]
start_response = request("Start provisioning", urls["midStartProvisioning"], {})
challenge = base64.b64decode(start_response["Response"]["spim"])
native = ctypes.CDLL(str(runtime / "libanisette-test.so"))
native.anisetteCoreSetLogging(0)
native.free_c_string.argtypes = [ctypes.c_void_p]
out_type = ctypes.POINTER(ctypes.c_void_p)
native.start_provision_uc.argtypes = [ctypes.c_char_p] * 4 + [ctypes.c_uint32, out_type]
native.cancel_provision_uc.argtypes = [ctypes.c_char_p] * 3 + [ctypes.c_uint32]
native.end_provision_uc.argtypes = (
    [ctypes.c_char_p] * 3 +
    [ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_uint32, out_type]
)

def native_call(stage, function, *args):
    output = ctypes.c_void_p()
    status = function(*args, ctypes.byref(output))
    print(f"{stage}: ADI {status}", flush=True)
    try:
        if status or not output.value:
            raise SystemExit(1)
        return json.loads(ctypes.string_at(output))
    finally:
        if output.value:
            native.free_c_string(output)

with tempfile.TemporaryDirectory() as work:
    inputs = (bytes(runtime), work.encode(), identifier.bytes)
    def start():
        return native_call("Native start", native.start_provision_uc, *inputs, challenge, len(challenge))
    initial = start()
    canceled = native.cancel_provision_uc(*inputs, initial["session"])
    print(f"Cancel active session: ADI {canceled}", flush=True)
    if canceled:
        raise SystemExit(1)
    current = start()
    try:
        reply = request("Finish provisioning", urls["midFinishProvisioning"], {"cpim": current["cpim_base64"]})
        result = reply.get("Response", {})
        if not result.get("ptm") or not result.get("tk"):
            status = reply.get("Status", {}).get("ec")
            if isinstance(status, int):
                print(f"Apple provisioning status: {status}", flush=True)
            raise SystemExit("Finish provisioning: Apple returned no provisioning tokens")
        ptm = base64.b64decode(result["ptm"])
        token = base64.b64decode(result["tk"])
        native_call(
            "Native finish", native.end_provision_uc, *inputs, current["session"],
            ptm, len(ptm), token, len(token)
        )
    except BaseException:
        print(f"Cancel after failed finish: ADI {native.cancel_provision_uc(*inputs, current['session'])}", flush=True)
        raise
