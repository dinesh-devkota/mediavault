"""Check the exact stock-server range semantics before contacting the VVD."""
import json
from pathlib import Path
import sys
from urllib.request import Request, urlopen

output = Path(sys.argv[1]).resolve()
checks = []
for name, mime in [("Controls.mkv", "video/x-matroska"), ("Controls.mp4", "video/mp4")]:
    data = (output / "media" / name).read_bytes()
    url = "http://127.0.0.1:8765/" + name
    with urlopen(Request(url, method="HEAD"), timeout=5) as response:
        assert response.status == 200
        assert int(response.headers["Content-Length"]) == len(data)
        assert response.headers["Content-Type"] == mime
        assert response.headers["Accept-Ranges"] == "bytes"
        checks.append({"file": name, "method": "HEAD", "status": response.status, "bytes": len(data)})
    for value, start, end in [("bytes=0-63", 0, 63),
                              (f"bytes={len(data)//2}-{len(data)//2+63}", len(data)//2, len(data)//2+63),
                              ("bytes=-64", len(data)-64, len(data)-1)]:
        with urlopen(Request(url, headers={"Range": value}), timeout=5) as response:
            assert response.status == 206
            assert response.headers["Content-Range"] == f"bytes {start}-{end}/{len(data)}"
            assert int(response.headers["Content-Length"]) == end-start+1
            assert response.read() == data[start:end+1]
            checks.append({"file": name, "method": "GET", "range": value, "status": response.status,
                           "contentRange": response.headers["Content-Range"], "bytes": end-start+1})
(output / "http-preflight.json").write_text(json.dumps(checks, indent=2) + "\n")
print("Verified HEAD and initial/middle/suffix 206 responses for both controls.")
