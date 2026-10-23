#!/usr/bin/env python3
"""Kleiner HTTP-Server fuer die Download-Tests: liefert eine Datei mit Range-Unterstuetzung.
Optionen: --drop-after N bricht die erste Antwort nach N Bytes ab (simuliert Verbindungsabbruch)."""
import http.server, os, sys, threading
path = sys.argv[1]; port = int(sys.argv[2]); drop = int(sys.argv[3]) if len(sys.argv) > 3 else 0
state = {'dropped': False}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        size = os.path.getsize(path); start = 0
        rng = self.headers.get('Range')
        if rng and rng.startswith('bytes='):
            start = int(rng[6:].split('-')[0])
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{size-1}/{size}')
        else:
            self.send_response(200)
        self.send_header('Content-Length', str(size - start))
        self.end_headers()
        with open(path, 'rb') as f:
            f.seek(start); sent = 0
            while True:
                chunk = f.read(65536)
                if not chunk: break
                if drop and not state['dropped'] and sent + len(chunk) > drop:
                    self.wfile.write(chunk[:max(0, drop - sent)]); self.wfile.flush()
                    state['dropped'] = True
                    self.connection.shutdown(2); return
                self.wfile.write(chunk); sent += len(chunk)
srv = http.server.ThreadingHTTPServer(('127.0.0.1', port), H)
print('ready', flush=True)
srv.serve_forever()
