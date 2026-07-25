#!/usr/bin/env python3
"""Agent Assistant — Clipboard Tool with OCR + Text Preview"""
import os, time, re, json, mimetypes
from http.server import HTTPServer, BaseHTTPRequestHandler

SAVE_DIR = '/tmp/clipboard'
os.makedirs(SAVE_DIR, exist_ok=True)

VERSION = '0.0.1'

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
    '.txt':'text/plain','.md':'text/markdown','.json':'application/json',
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
HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>📋 云剪切板</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font:14px system-ui;background:#1a1a2e;color:#eee;min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:20px}
.zone{border:3px dashed #555;border-radius:20px;padding:50px 30px;text-align:center;cursor:pointer;margin:20px 0;width:90%;max-width:500px;min-height:200px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px;transition:.3s}
.zone:hover,.zone.dragover{border-color:#7c5ce7;background:#252540}
.zone .icons{font-size:52px}
.zone .title{color:#7c5ce7;font-size:20px;font-weight:600}
.zone .sub{color:#888;font-size:13px}
.hint{color:#555;margin-top:12px;font-size:13px;text-align:center;line-height:1.6}
.result{margin-top:24px;max-width:600px;width:95%}
.item{display:flex;align-items:center;gap:12px;background:#222;padding:10px 14px;border-radius:10px;margin:8px 0;animation:slideIn .3s}
@keyframes slideIn{from{opacity:0;transform:translateY(-10px)}to{opacity:1;transform:translateY(0)}}
.item .preview{max-width:120px;max-height:80px;border-radius:6px;object-fit:contain;flex-shrink:0;background:#1a1a2e}
.item .icon2{font-size:32px;width:60px;text-align:center;flex-shrink:0}
.item .info{flex:1;min-width:0}
.item .path{color:#7c5ce7;font-size:13px;font-family:monospace;word-break:break-all;cursor:pointer;line-height:1.4}
.item .path:hover{text-decoration:underline}
.item .meta{color:#777;font-size:11px;margin-top:3px}
.item .actions{display:flex;gap:6px;flex-shrink:0}
.item .actions button{background:#333;border:none;color:#aaa;padding:6px 12px;border-radius:6px;cursor:pointer;font-size:12px}
.item .actions button:hover{background:#555;color:#fff}
.item .actions .del:hover{background:#c0392b;color:#fff}
.item .actions .copy.copied{background:#4caf50;color:#fff}
.item .actions .ocr-btn{background:#7c5ce7;color:#fff}
.item .actions .ocr-btn:hover{background:#9b7ef7}
.item .actions .text-btn{background:#2980b9;color:#fff}
.item .actions .text-btn:hover{background:#3498db}
footer{position:fixed;bottom:20px;color:#444;font-size:12px}
footer a{color:#666;text-decoration:none}

/* OCR Modal */
#ocr-modal{position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.85);display:none;flex-direction:row;align-items:center;justify-content:center;gap:0;padding:20px}
#ocr-modal.show{display:flex}
#ocr-modal .ocr-left{flex:1;height:80vh;display:flex;flex-direction:column;align-items:center;justify-content:center;border-right:2px solid #444;padding-right:20px}
#ocr-modal .ocr-left img{max-width:100%;max-height:75vh;border-radius:8px;box-shadow:0 0 40px rgba(0,0,0,.5)}
#ocr-modal .ocr-right{flex:1.2;height:80vh;display:flex;flex-direction:column;padding-left:20px}
#ocr-modal .ocr-right h3{color:#7c5ce7;margin-bottom:12px;font-size:16px}
#ocr-modal .ocr-toolbar{display:flex;gap:8px;margin-bottom:10px;flex-wrap:wrap}
#ocr-modal .ocr-toolbar button{background:#333;border:none;color:#aaa;padding:6px 14px;border-radius:6px;cursor:pointer;font-size:12px}
#ocr-modal .ocr-toolbar button:hover{background:#555;color:#fff}
#ocr-modal .ocr-toolbar .copy-ocr.copied{background:#4caf50;color:#fff}
#ocr-modal textarea{width:100%;flex:1;background:#1a1a2e;border:1px solid #333;border-radius:8px;color:#eee;padding:12px;font-family:monospace;font-size:13px;resize:none;line-height:1.6}
#ocr-modal .close-btn{position:fixed;top:20px;right:30px;background:#333;border:none;color:#fff;padding:8px 20px;border-radius:6px;cursor:pointer;font-size:14px}

/* Text Preview Modal */
#text-modal{position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.85);display:none;flex-direction:column;align-items:center;justify-content:center;padding:20px}
#text-modal.show{display:flex}
#text-modal .box{background:#1a1a2e;border:1px solid #333;border-radius:12px;max-width:800px;width:95%;max-height:88vh;display:flex;flex-direction:column;overflow:hidden}
#text-modal .hdr{padding:14px 20px;border-bottom:1px solid #333;display:flex;align-items:center;gap:12px;flex-shrink:0}
#text-modal .hdr .ttl{font-size:20px}
#text-modal .hdr .fname{color:#7c5ce7;font-size:15px;font-weight:600;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#text-modal .hdr .meta{color:#777;font-size:12px}
#text-modal .hdr button{background:#333;border:none;color:#aaa;padding:6px 14px;border-radius:6px;cursor:pointer;font-size:12px}
#text-modal .hdr button:hover{background:#555;color:#fff}
#text-modal .hdr .copy-btn.copied{background:#4caf50;color:#fff}
#text-modal .hdr .view-btn{background:#7c5ce7;color:#fff;text-decoration:none;padding:6px 14px;border-radius:6px;font-size:12px}
#text-modal .hdr .close-x{background:#444;margin-left:4px}
#text-modal .body{overflow-y:auto;flex:1;padding:16px 20px;color:#ccc;font-family:monospace;font-size:13px;line-height:1.6;white-space:pre-wrap;word-break:break-all;background:#16162a;margin:12px;border-radius:8px;border:1px solid #2a2a44}
#text-modal .body .placeholder{color:#888;font-style:italic}
#text-modal .body .ellipsis{color:#7c5ce7;cursor:pointer;text-decoration:underline}
</style></head><body>
<div class="zone" id="zone" tabindex="0">
  <div class="icons">📎</div>
  <div class="title">Cmd+V 贴入或拖放文件</div>
  <div class="sub">支持：截图 · 文件 · 文本 · 图片OCR</div>
</div>
<div class="hint" id="hint">点选上方区域后 Cmd+V，或直接从 Finder 拖文件入来</div>
<div class="result" id="result"></div>
<footer>保存到 /tmp/clipboard/ | <a href="javascript:clearHistory()">清记录</a> | v<span id="ver">__VERSION__</span></footer>

<!-- OCR Modal -->
<div id="ocr-modal">
  <div class="ocr-left"><img id="ocr-img" src="" alt="source"></div>
  <div class="ocr-right">
    <h3>📝 OCR 结果</h3>
    <div class="ocr-toolbar">
      <button class="copy-ocr" id="copy-ocr-btn" onclick="copyOcrText()">📋 复制全部</button>
      <button onclick="selectAllOcr()">全选</button>
      <button onclick="closeOcrModal()" style="background:#444;margin-left:auto">关闭</button>
    </div>
    <textarea id="ocr-text" placeholder="正在识别..."></textarea>
  </div>
  <button class="close-btn" onclick="closeOcrModal()">✕</button>
</div>

<!-- Text Preview Modal -->
<div id="text-modal">
  <div class="box">
    <div class="hdr">
      <span class="ttl">📝</span>
      <span class="fname" id="t-fname"></span>
      <span class="meta" id="t-meta"></span>
      <button class="copy-btn" id="t-copy" onclick="copyFullText()">📋 复制全文</button>
      <a class="view-btn" id="t-view" href="" target="_blank">🔍 原文</a>
      <button class="close-x" onclick="closeTextModal()">关闭</button>
    </div>
    <div class="body" id="t-body"><span class="placeholder">加载中...</span></div>
  </div>
</div>

<script>
var zone = document.getElementById('zone');
var result = document.getElementById('result');
var hint = document.getElementById('hint');
zone.onclick = function() { zone.focus() };

var saved = JSON.parse(localStorage.getItem('cb') || '[]');
function saveHistory() { localStorage.setItem('cb', JSON.stringify(saved)) }
function clearHistory() { saved = []; saveHistory(); result.innerHTML = '' }

// ── helpers ──────────────────────────────────────────────────────────────
function isImage(fn) {
    var ext = fn.split('.').pop().toLowerCase();
    return ext === 'png' || ext === 'jpg' || ext === 'jpeg' || ext === 'gif' || ext === 'webp' || ext === 'bmp' || ext === 'svg';
}
function isText(fn) {
    var ext = fn.split('.').pop().toLowerCase();
    return ext === 'txt' || ext === 'md' || ext === 'py' || ext === 'sh' || ext === 'js' || ext === 'json' || ext === 'html' || ext === 'css' || ext === 'xml' || ext === 'yml' || ext === 'yaml' || ext === 'srt' || ext === 'log';
}
function iconFor(fn) {
    var map = {png:'🖼',jpg:'🖼',jpeg:'🖼',gif:'🖼',webp:'🖼',bmp:'🖼',svg:'🖼',zip:'📦',tar:'📦',gz:'📦',dmg:'💿',pdf:'📄',doc:'📝',xls:'📊',mp3:'🎵',wav:'🎵',mp4:'🎬',txt:'📃',md:'📃',py:'🐍',sh:'⚡',js:'📜',json:'📋',srt:'💬'};
    var txtMap = {txt:'📃',md:'📃',py:'🐍',sh:'⚡',js:'📜',json:'📋',html:'🌐',css:'🎨',xml:'📰',yml:'⚙',yaml:'⚙',srt:'💬',log:'📝'};
    var ext = fn.split('.').pop().toLowerCase();
    if (isImage(fn)) return '🖼';
    if (txtMap[ext]) return txtMap[ext];
    return map[ext] || '📁';
}

function renderHistory() {
    if (!saved.length) { result.innerHTML = ''; return; }
    result.innerHTML = saved.slice().reverse().map(function(p) { return itemHTML(p.name, p.path); }).join('');
}
renderHistory();

function itemHTML(name, path) {
    var enc = encodeURIComponent(path);
    var imgPrev = '';
    if (isImage(name)) {
        imgPrev = '<img class="preview" src="' + path + '" loading="lazy" onclick="showImage(\'' + path + '\')" style="cursor:pointer">';
    }
    var ocrBtn = isImage(name) ? '<button class="ocr-btn" onclick="doOcr(\'' + enc + '\', \'' + path + '\')">🔍 OCR</button>' : '';
    var textBtn = isText(name) ? '<button class="text-btn" onclick="showTextPreview(\'' + enc + '\', \'' + path + '\')">📝 预览</button>' : '';
    return '<div class="item">' +
        (imgPrev || '<div class="icon2">' + iconFor(name) + '</div>') +
        '<div class="info">' +
            '<div class="path" title="点击复制路径" onclick="copyPath(this, \'' + path + '\')">' + path + '</div>' +
            '<div class="meta">' + name + '</div>' +
        '</div>' +
        '<div class="actions">' +
            '<button class="copy" onclick="copyPath(this.parentElement.parentElement.querySelector(\'.path\'), \'' + path + '\')">📋</button>' +
            textBtn +
            ocrBtn +
            '<button class="del" onclick="delFile(\'' + enc + '\', this.parentElement.parentElement, event)">🗑</button>' +
        '</div>' +
    '</div>';
}

function copyPath(el, path) {
    navigator.clipboard.writeText(path).then(function() {
        el.textContent = '✅'; el.style.color = '#4caf50';
        setTimeout(function() { el.textContent = path; el.style.color = '#7c5ce7'; }, 2000);
    }).catch(function() {});
}

function delFile(encPath, itemEl, event) {
    var cf = document.createElement('div');
    cf.innerHTML = '确认删除？<br><span style="font-size:11px;color:#888">' + decodeURIComponent(encPath).split('/').pop() + '</span>';
    cf.style.cssText = 'position:fixed;z-index:999;background:#2a2a40;border:1px solid #7c5ce7;border-radius:8px;padding:12px 16px;color:#eee;font-size:13px;text-align:center;box-shadow:0 4px 12px rgba(0,0,0,.5)';
    if (event) { cf.style.left = Math.min(event.clientX, window.innerWidth - 180) + 'px'; cf.style.top = (event.clientY - 80) + 'px'; }
    var btns = document.createElement('div'); btns.style.cssText = 'display:flex;gap:8px;justify-content:center;margin-top:10px';
    var yes = document.createElement('button'); yes.textContent = '🗑 删除'; yes.style.cssText = 'background:#c0392b;color:#fff;border:none;padding:6px 16px;border-radius:6px;cursor:pointer;font-size:13px';
    var no = document.createElement('button'); no.textContent = '取消'; no.style.cssText = 'background:#444;color:#aaa;border:none;padding:6px 16px;border-radius:6px;cursor:pointer;font-size:13px';
    yes.onclick = function() {
        cf.remove();
        fetch('/del?path=' + encPath, {method:'DELETE'}).then(function(r) {
            if (r.ok) {
                itemEl.style.opacity = '0'; itemEl.style.transform = 'translateX(-20px)'; itemEl.style.transition = '.3s';
                setTimeout(function() {
                    itemEl.remove();
                    saved = saved.filter(function(p) { return p.path !== decodeURIComponent(encPath); });
                    saveHistory();
                }, 300);
            }
        });
    };
    no.onclick = function() { cf.remove() };
    btns.appendChild(yes); btns.appendChild(no); cf.appendChild(btns); document.body.appendChild(cf);
    setTimeout(function() {
        document.addEventListener('click', function tmp(e) {
            if (!cf.contains(e.target)) { cf.remove(); document.removeEventListener('click', tmp); }
        });
    }, 100);
}

function showImage(src) {
    var ov = document.createElement('div');
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,.85);display:flex;align-items:center;justify-content:center;cursor:pointer';
    var img = document.createElement('img'); img.src = src; img.style.cssText = 'max-width:90vw;max-height:90vh;border-radius:8px;box-shadow:0 0 40px rgba(0,0,0,.5)';
    ov.appendChild(img); ov.onclick = function() { ov.remove() }; document.body.appendChild(ov);
}

// ── upload ──────────────────────────────────────────────────────────────
function upload(blob, filename) {
    var fd = new FormData(); fd.append('f', blob, filename);
    fetch('/up', {method:'POST', body:fd}).then(function(r) { return r.text() }).then(function(path) {
        saved.push({name: filename, path: path}); saveHistory();
        result.insertAdjacentHTML('afterbegin', itemHTML(filename, path));
        hint.textContent = '✅ ' + filename;
        setTimeout(function() { hint.textContent = '点选上方区域后 Cmd+V，或直接从 Finder 拖文件入来'; }, 3000);
    });
}
function uploadText(text) {
    var fd = new FormData(); fd.append('text', text);
    fetch('/up', {method:'POST', body:fd}).then(function(r) { return r.text() }).then(function(path) {
        var name = '文本.txt';
        saved.push({name: name, path: path}); saveHistory();
        result.insertAdjacentHTML('afterbegin', itemHTML(name, path));
        hint.textContent = '✅ 文本已保存';
        setTimeout(function() { hint.textContent = '点选上方区域后 Cmd+V，或直接从 Finder 拖文件入来'; }, 3000);
    });
}

// ── OCR ─────────────────────────────────────────────────────────────────
function doOcr(encPath, rawPath) {
    var modal = document.getElementById('ocr-modal');
    var img = document.getElementById('ocr-img');
    var text = document.getElementById('ocr-text');
    img.src = rawPath;
    text.value = '正在识别...';
    modal.classList.add('show');
    fetch('/ocr?path=' + encPath)
        .then(function(r) { return r.json() })
        .then(function(data) {
            if (data.success) { text.value = data.text.trim(); }
            else { text.value = '❌ OCR 失败：' + data.error; }
        })
        .catch(function(e) { text.value = '❌ 网络错误：' + e; });
}
function closeOcrModal() { document.getElementById('ocr-modal').classList.remove('show'); }
function copyOcrText() {
    var text = document.getElementById('ocr-text');
    text.select(); document.execCommand('selectAll', false, null);
    navigator.clipboard.writeText(text.value).then(function() {
        var btn = document.getElementById('copy-ocr-btn');
        btn.textContent = '✅ 已复制'; btn.classList.add('copied');
        setTimeout(function() { btn.textContent = '📋 复制全部'; btn.classList.remove('copied'); }, 2000);
    }).catch(function() { document.execCommand('copy'); });
}
function selectAllOcr() {
    var text = document.getElementById('ocr-text');
    text.select(); document.execCommand('selectAll', false, null);
}

// ── Text Preview ───────────────────────────────────────────────────────
window._currentText = '';
function showTextPreview(encPath, rawPath) {
    var modal = document.getElementById('text-modal');
    var fnameEl = document.getElementById('t-fname');
    var metaEl = document.getElementById('t-meta');
    var bodyEl = document.getElementById('t-body');
    var copyBtn = document.getElementById('t-copy');
    var viewBtn = document.getElementById('t-view');

    fnameEl.textContent = rawPath.split('/').pop();
    metaEl.textContent = '加载中...';
    bodyEl.innerHTML = '<span class="placeholder">加载中...</span>';
    viewBtn.href = rawPath;
    copyBtn.textContent = '📋 复制全文'; copyBtn.classList.remove('copied');
    window._currentText = '';
    modal.classList.add('show');

    fetch('/preview?path=' + encPath)
        .then(function(r) { return r.json() })
        .then(function(data) {
            if (data.success) {
                var totalStr = data.total + ' 字符';
                var display = data.preview.replace(/</g, '&lt;').replace(/>/g, '&gt;');
                if (data.hasMore) {
                    display += ' <span class="ellipsis" onclick="loadFullText(\'' + encPath + '\')">... (' + (data.total - 'TEXT_PREVIEW_CHARS' + 0) + ' 更多字符，点击展开)</span>';
                }
                bodyEl.innerHTML = display;
                metaEl.textContent = totalStr;
                window._currentText = data.preview;
            } else {
                bodyEl.innerHTML = '<span class="placeholder">❌ 读取失败</span>';
                metaEl.textContent = '';
            }
        })
        .catch(function(e) {
            bodyEl.innerHTML = '<span class="placeholder">❌ 网络错误</span>';
            metaEl.textContent = '';
        });
}
function loadFullText(encPath) {
    fetch('/text?path=' + encPath)
        .then(function(r) { return r.text() })
        .then(function(text) {
            document.getElementById('t-body').innerHTML = text.replace(/</g, '&lt;').replace(/>/g, '&gt;');
            window._currentText = text;
        });
}
function copyFullText() {
    var text = window._currentText || '';
    if (!text) return;
    navigator.clipboard.writeText(text).then(function() {
        var btn = document.getElementById('t-copy');
        btn.textContent = '✅ 已复制'; btn.classList.add('copied');
        setTimeout(function() { btn.textContent = '📋 复制全文'; btn.classList.remove('copied'); }, 2000);
    });
}
function closeTextModal() { document.getElementById('text-modal').classList.remove('show'); }

// ── events ──────────────────────────────────────────────────────────────
document.onpaste = function(e) {
    e.preventDefault();
    for (var i = 0; i < e.clipboardData.items.length; i++) {
        var item = e.clipboardData.items[i];
        if (item.kind === 'file') {
            var file = item.getAsFile();
            upload(file, file.name || 'clipboard_' + Date.now());
            break;
        } else if (item.kind === 'string') {
            item.getAsString(function(text) { if (text.length > 0) uploadText(text); });
            break;
        }
    }
};
zone.ondragover = function(e) { e.preventDefault(); zone.classList.add('dragover') };
zone.ondragleave = function() { zone.classList.remove('dragover') };
zone.ondrop = function(e) {
    e.preventDefault(); zone.classList.remove('dragover');
    for (var i = 0; i < e.dataTransfer.files.length; i++) {
        upload(e.dataTransfer.files[i], e.dataTransfer.files[i].name);
    }\n};\n\n// ── auto-load from server ─────────────────────────────────────────\nfunction loadFromServer() {\n    fetch('/list').then(function(r) { return r.json() }).then(function(files) {\n        var savedPaths = {};\n        saved.forEach(function(p) { savedPaths[p.path] = true });\n        files.forEach(function(f) {\n            if (!savedPaths[f.path]) {\n                saved.push({name: f.name, path: f.path});\n            }\n        });\n        saveHistory();\n        renderHistory();\n    });\n}\nloadFromServer();\n</script></body></html>
"""

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
                        fn = str(int(time.time() * 1000)) + '.txt'
                        path = os.path.join(SAVE_DIR, fn)
                        open(path, 'wb').write(body)
                        print('SAVED:', path, '(' + str(len(body)) + 'b text)')
                        self._r(200, 'text/plain', path.encode())
                        return
            self._r(400)
        else:
            self._r(404)

    def do_DELETE(self):
        if self.path.startswith('/del?path='):
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
