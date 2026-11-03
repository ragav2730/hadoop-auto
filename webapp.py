#!/usr/bin/env python3
"""Small local WordCount UI for the Hadoop 2.7.0 single-node lab."""
import argparse
import html
import os
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

MAX_UPLOAD = 5 * 1024 * 1024
LOCK = threading.Lock()

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hadoop WordCount Lab</title>
<style>
:root{font-family:Inter,system-ui,Arial,sans-serif;color:#172033;background:#f4f7fb}
*{box-sizing:border-box}body{margin:0}.wrap{max-width:900px;margin:42px auto;padding:0 18px}
header{background:linear-gradient(120deg,#102b50,#1766a6);color:white;padding:30px;border-radius:18px}
h1{margin:0 0 8px;font-size:28px}.muted{color:#667085}.white{color:#dcecff}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:14px;margin:18px 0}
.card{background:white;border:1px solid #e5eaf1;border-radius:14px;padding:18px;box-shadow:0 4px 18px #1b36500b}
.port{font-size:22px;font-weight:750;color:#1766a6}.label{font-size:13px;color:#667085}
form{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-top:14px}
input[type=file]{padding:12px;border:1px solid #d6deea;border-radius:9px;background:#fff;max-width:100%}
button{background:#1766a6;color:#fff;border:0;border-radius:9px;padding:13px 20px;font-weight:700;cursor:pointer}
button:hover{background:#10548d}.hint{font-size:13px;color:#667085;margin-top:10px}
.result{white-space:pre-wrap;overflow:auto;background:#101b2b;color:#d8f3df;padding:18px;border-radius:12px;line-height:1.55}
.error{background:#fff1f0;border:1px solid #ffc9c5;color:#9b1c1c;padding:14px;border-radius:10px;white-space:pre-wrap}
a{color:#1766a6}footer{color:#7a8495;font-size:12px;margin:22px 0}
</style></head><body><div class="wrap">
<header><h1>Hadoop WordCount</h1><div class="white">Big Data Analytics Laboratory · Experiment 2 · MapReduce</div></header>
<div class="grid">
<div class="card"><div class="label">Hadoop NameNode</div><div class="port">:50070</div><a href="http://localhost:50070" target="_blank">Open HDFS dashboard ↗</a></div>
<div class="card"><div class="label">YARN ResourceManager</div><div class="port">:8088</div><a href="http://localhost:8088" target="_blank">Open YARN dashboard ↗</a></div>
<div class="card"><div class="label">WordCount application</div><div class="port">:8000</div><div class="label">This page</div></div>
</div>
<section class="card"><h2>Run WordCount</h2><p class="muted">Choose a plain-text (.txt) file. The app uploads it to HDFS, runs Hadoop MapReduce, and displays each word's frequency.</p>
<form method="post" action="/run" enctype="multipart/form-data">
<input type="file" name="file" accept=".txt,text/plain" required>
<button type="submit">Upload &amp; Run WordCount</button></form>
<div class="hint">Maximum file size: 5 MB. A new unique HDFS output folder is created for each run.</div></section>
{RESULT}
<footer>Runs locally on this Ubuntu computer. Keep the terminal session and Hadoop services running.</footer>
</div></body></html>"""

def run_cmd(args, timeout=240):
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, timeout=timeout)
    if proc.returncode:
        raise RuntimeError("$ " + " ".join(args) + "\n" + proc.stdout[-12000:])
    return proc.stdout

def render(result=""):
    return PAGE.replace("{RESULT}", result), "text/html; charset=utf-8"

class Handler(BaseHTTPRequestHandler):
    server_version = "HadoopWordCountUI/1.0"

    def respond(self, code, body, content_type="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        body, ctype = render()
        self.respond(200, body, ctype)

    def do_POST(self):
        if self.path != "/run":
            self.respond(404, "Not found", "text/plain")
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_UPLOAD + 1024 * 1024:
            self.respond(413, render('<div class="error">Upload is empty or larger than 5 MB.</div>')[0])
            return
        content_type = self.headers.get("Content-Type", "")
        boundary = None
        for part in content_type.split(";"):
            if "boundary=" in part:
                boundary = part.split("=", 1)[1].strip().strip('"')
        if not boundary:
            self.respond(400, render('<div class="error">Invalid upload form.</div>')[0])
            return
        raw = self.rfile.read(length)
        marker = ("--" + boundary).encode()
        file_bytes = None
        filename = "input.txt"
        for section in raw.split(marker):
            if b'Content-Disposition:' in section and b'name="file"' in section:
                head, sep, payload = section.partition(b"\r\n\r\n")
                if sep:
                    payload = payload.rsplit(b"\r\n", 1)[0]
                    for line in head.decode("utf-8", "ignore").split("\r\n"):
                        if "filename=" in line:
                            filename = line.split("filename=", 1)[1].strip().strip('"')
                    file_bytes = payload
                    break
        if file_bytes is None or not file_bytes:
            self.respond(400, render('<div class="error">Please select a non-empty .txt file.</div>')[0])
            return
        if len(file_bytes) > MAX_UPLOAD:
            self.respond(413, render('<div class="error">Maximum upload size is 5 MB.</div>')[0])
            return
        if not filename.lower().endswith(".txt"):
            self.respond(400, render('<div class="error">Please upload a .txt file.</div>')[0])
            return

        with LOCK:
            try:
                hadoop = os.environ.get("HADOOP_HOME", str(Path.home() / "hadoop-2.7.0"))
                hdfs = str(Path(hadoop) / "bin" / "hdfs")
                hadoop_cmd = str(Path(hadoop) / "bin" / "hadoop")
                examples = str(Path(hadoop) / "share/hadoop/mapreduce/hadoop-mapreduce-examples-2.7.0.jar")
                if not Path(hdfs).is_file() or not Path(examples).is_file():
                    raise RuntimeError("Hadoop 2.7.0 was not found. Run the installer again.")
                run_id = time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
                with tempfile.NamedTemporaryFile(prefix="hadoop-wordcount-", suffix=".txt", delete=False) as f:
                    f.write(file_bytes)
                    local_file = f.name
                hdfs_input = "/user1/web-" + run_id + ".txt"
                hdfs_output = "/wordcount-output-" + run_id
                try:
                    run_cmd([hdfs, "dfs", "-mkdir", "-p", "/user1"])
                    run_cmd([hdfs, "dfs", "-put", local_file, hdfs_input])
                    run_cmd([hadoop_cmd, "jar", examples, "wordcount", hdfs_input, hdfs_output])
                    output = run_cmd([hdfs, "dfs", "-cat", hdfs_output + "/part-r-00000"])
                finally:
                    try: os.unlink(local_file)
                    except OSError: pass
                safe_name = html.escape(Path(filename).name)
                result = ('<section class="card"><h2>WordCount result</h2><p class="muted">Input: '
                          + safe_name + ' · HDFS output: ' + html.escape(hdfs_output)
                          + '</p><pre class="result">' + html.escape(output.strip())
                          + '</pre></section>')
                body, _ = render(result)
                self.respond(200, body)
            except subprocess.TimeoutExpired:
                body, _ = render('<div class="error">The MapReduce job timed out. Check Hadoop/YARN status and try a smaller file.</div>')
                self.respond(504, body)
            except Exception as exc:
                body, _ = render('<div class="error">' + html.escape(str(exc)) + '</div>')
                self.respond(500, body)

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"WordCount dashboard listening on http://localhost:{args.port}", flush=True)
    server.serve_forever()

if __name__ == "__main__":
    main()

