#!/usr/bin/env python3
"""Agent Assistant — Clipboard Tool with OCR + Text Preview"""
import os, time, re, json, mimetypes
from http.server import HTTPServer, BaseHTTPRequestHandler

SAVE_DIR = '/tmp/clipboard'
os.makedirs(SAVE_DIR, exist_ok=True)

VERSION = '0.0.6'

_ocr_engine = None

def get_ocr():
    global _ocr_engine
    if _ocr_engine is None:
        from rapidocr_onnxruntime import RapidOCR
        _ocr_engine = RapidOCR()
        import numpy as np
        blank = np.ones((64, 64, 3), dtype=np.uint8) * 255
        _ocr_engine(blank)
    return _ocr_engine

def _prewarm_ocr():
    global _ocr_engine
    if _ocr_engine is None:
        get_ocr()

MIME_MAP = {
    '.txt':'text/plain','.text':'text/plain','.md':'text/markdown','.json':'application/json',
    '.py':'text/x-python','.sh':'text/x-shellscript','.js':'text/javascript',
    '.html':'text/html','.css':'text/css','.xml':'text/xml','.yml':'text/yaml',
    '.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg',
    '.gif':'image/gif','.webp':'image/webp','.svg':'image/svg+xml',
    '.pdf':'application/pdf','.zip':'application/zip'
}
IMAGE_EXTS = {'.png','.jpg','.jpeg','.gif','.webp','.bmp','.svg'}
TEXT_EXTS = {'.txt','.md','.py','.sh','.js','.json','.html','.css','.xml','.yml','.yaml','.srt','.log'}
MAX_PIXELS = 1200
TEXT_PREVIEW_CHARS = 200

def guess_mime(fn):
    ext = os.path.splitext(fn)[1].lower()
    return MIME_MAP.get(ext, mimetypes.guess_type(fn)[0] or 'application/octet-stream')

def is_image_file(fn):
    return os.path.splitext(fn)[1].lower() in IMAGE_EXTS

def is_text_file(fn):
    return os.path.splitext(fn)[1].lower() in TEXT_EXTS

# ─── HTML ───────────────────────────────────────────────────────────────────
HTML = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'index.html')).read()
HTML = HTML.replace('__VERSION__', VERSION)

# ─── HTTP Handler ────────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self._r(200, 'text/html', HTML.encode())
        elif self.path == '/list':
            self._do_list()
        elif self.path.startswith('/tmp/clipboard/'):
            fn = self.path.split('?')[0]
            if os.path.isfile(fn):
                self._r(200, guess_mime(fn), open(fn, 'rb').read())
            else:
                self._r(404)
        elif self.path.startswith('/ocr?path='):
            self._do_ocr()
        elif self.path.startswith('/preview?path='):
            self._do_preview()
        elif self.path.startswith('/text?path='):
            self._do_text()
        else:
            self._r(404)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        if self.path == '/up':
            ct = self.headers.get('Content-Type', '')
            cl = int(self.headers.get('Content-Length', 0))
            data = self.rfile.read(cl)
            if 'multipart' in ct:
                bd = ct.split('boundary=')[1].encode()
                for part in data.split(b'--' + bd):
                    if b'filename=' in part:
                        hdr_end = part.find(b'\r\n\r\n')
                        if hdr_end < 0:
                            continue
                        body = part[hdr_end + 4:]
                        if body.endswith(b'\r\n'):
                            body = body[:-2]
                        m = re.search(rb'filename="?([^"\r\n]+)', part[:hdr_end])
                        fn = m.group(1).decode('utf-8', errors='ignore') if m else str(int(time.time() * 1000)) + '.bin'
                        path = os.path.join(SAVE_DIR, fn)
                        if os.path.exists(path):
                            base, ext = os.path.splitext(fn)
                            path = os.path.join(SAVE_DIR, base + '_' + str(int(time.time() * 1000)) + ext)
                        open(path, 'wb').write(body)
                        print('SAVED:', path, '(' + str(len(body)) + 'b)')
                        self._r(200, 'text/plain', path.encode())
                        return
                    elif b'name="text"' in part:
                        hdr_end = part.find(b'\r\n\r\n')
                        if hdr_end < 0:
                            continue
                        body = part[hdr_end + 4:]
                        if body.endswith(b'\r\n'):
                            body = body[:-2]
                        fn = str(int(time.time() * 1000)) + '.text'
                        path = os.path.join(SAVE_DIR, fn)
                        open(path, 'wb').write(body)
                        print('SAVED:', path, '(' + str(len(body)) + 'b text)')
                        self._r(200, 'text/plain', path.encode())
                        return
            self._r(400)
        else:
            self._r(404)

    def do_DELETE(self):
        if self.path == '/del-all':
            count = 0
            for fn in os.listdir(SAVE_DIR):
                real = os.path.realpath(os.path.join(SAVE_DIR, fn))
                if real.startswith(os.path.realpath(SAVE_DIR)) and os.path.isfile(real):
                    os.remove(real)
                    count += 1
            print('DELETED ALL: %d files' % count)
            self._r(200, 'text/plain', ('deleted ' + str(count) + ' files').encode())
        elif self.path.startswith('/del?path='):
            import urllib.parse
            fn = urllib.parse.unquote(self.path.split('?path=', 1)[1])
            real = os.path.realpath(fn)
            if real.startswith(os.path.realpath(SAVE_DIR)) and os.path.isfile(real):
                os.remove(real)
                print('DELETED:', real)
                self._r(200, 'text/plain', b'ok')
            else:
                self._r(404)
        else:
            self._r(404)

    def _do_ocr(self):
        import urllib.parse
        enc_path = self.path.split('?path=', 1)[1]
        fn = urllib.parse.unquote(enc_path)
        real = os.path.realpath(fn)
        if not real.startswith(os.path.realpath(SAVE_DIR)):
            self._json(403, {'success': False, 'error': 'Forbidden'}); return
        if not os.path.isfile(real):
            self._json(404, {'success': False, 'error': 'File not found'}); return
        ext = os.path.splitext(real)[1].lower()
        if ext not in IMAGE_EXTS:
            self._json(400, {'success': False, 'error': 'Not an image file'}); return
        try:
            from PIL import Image as PILImage
            ocr = get_ocr()
            img = PILImage.open(real)
            w, h = img.size
            if max(w, h) > MAX_PIXELS:
                img.thumbnail((MAX_PIXELS, MAX_PIXELS), PILImage.LANCZOS)
            result, elapse = ocr(img)
            if result is None or len(result) == 0:
                self._json(200, {'success': True, 'text': '(未识别到文字)'}); return
            from collections import defaultdict
            row_map = defaultdict(list)
            for item in result:
                box = item[0]
                text = item[1]
                y_top = (box[0][1] + box[1][1]) / 2.0
                row_key = round(y_top / 10.0) * 10.0
                x_left = (box[0][0] + box[3][0]) / 2.0
                row_map[row_key].append((x_left, text))
            rows = []
            for y, items in sorted(row_map.items()):
                items.sort(key=lambda x: x[0])
                rows.append(' '.join(t for _, t in items))
            full_text = '\n'.join(rows)
            print('OCR: %s -> %d blocks -> %d rows, %d chars' % (real, len(result), len(rows), len(full_text)))
            self._json(200, {'success': True, 'text': full_text})
        except Exception as e:
            print('OCR error: %s' % e)
            self._json(500, {'success': False, 'error': str(e)})

    def _do_preview(self):
        import urllib.parse
        enc_path = self.path.split('?path=', 1)[1]
        fn = urllib.parse.unquote(enc_path)
        real = os.path.realpath(fn)
        if not real.startswith(os.path.realpath(SAVE_DIR)):
            self._json(403, {'success': False, 'error': 'Forbidden'}); return
        if not os.path.isfile(real):
            self._json(404, {'success': False, 'error': 'File not found'}); return
        try:
            content = open(real, 'rb').read().decode('utf-8', errors='ignore')
            preview = content[:TEXT_PREVIEW_CHARS]
            self._json(200, {
                'success': True,
                'preview': preview,
                'hasMore': len(content) > TEXT_PREVIEW_CHARS,
                'total': len(content)
            })
        except Exception as e:
            self._json(500, {'success': False, 'error': str(e)})

    def _do_text(self):
        import urllib.parse
        enc_path = self.path.split('?path=', 1)[1]
        fn = urllib.parse.unquote(enc_path)
        real = os.path.realpath(fn)
        if not real.startswith(os.path.realpath(SAVE_DIR)):
            self._r(403); return
        if not os.path.isfile(real):
            self._r(404); return
        try:
            body = open(real, 'rb').read()
            self._r(200, 'text/plain; charset=utf-8', body)
        except:
            self._r(500)

    def _do_list(self):
        import os
        files = []
        for fn in sorted(os.listdir(SAVE_DIR), key=lambda x: os.path.getmtime(os.path.join(SAVE_DIR, x)), reverse=True):
            path = os.path.join(SAVE_DIR, fn)
            if os.path.isfile(path):
                files.append({'name': fn, 'path': path})
        self._json(200, files)

    def _send_no_cache(self):
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', len(body))
        self._send_no_cache()
        self.end_headers()
        self.wfile.write(body)

    def _r(self, code, ct='text/plain', body=b''):
        self.send_response(code)
        self.send_header('Content-Type', ct)
        self.send_header('Content-Length', len(body))
        self._send_no_cache()
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args): pass

# ─── Main ───────────────────────────────────────────────────────────────────
os.environ.setdefault('OMP_NUM_THREADS', '8')
os.environ.setdefault('MKL_NUM_THREADS', '8')
os.environ.setdefault('OPENBLAS_NUM_THREADS', '8')

print('📋 Agent Assistant Clipboard on :9191')
print('🔍 Loading OCR models...')
_prewarm_ocr()
print('🔍 OCR ready. Max resize: %dpx | Text preview: %d chars' % (MAX_PIXELS, TEXT_PREVIEW_CHARS))
print('🚀 Server running on http://localhost:9191')
HTML = HTML.replace('__VERSION__', VERSION)
server = HTTPServer(('0.0.0.0', 9191), Handler)
server.serve_forever()
