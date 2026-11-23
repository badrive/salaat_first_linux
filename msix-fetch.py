#!/usr/bin/env python3
"""Extracts app/* and bin/*.exe from Salaat First's x64 MSIX into OUT, after checking Microsoft's signature.
Usage: msix-fetch.py URL_OR_FILE OLD OUT
URL_OR_FILE is the .msixbundle (or one .msix). Blocks that already exist in any file under OLD (the
previous release's output; may be empty) are copied from there. The rest are fetched with HTTP range
requests, so an update downloads only the 64 KB blocks that changed."""
import base64, hashlib, http.client, io, os, ssl, subprocess, sys, tempfile, urllib.parse, urllib.request, zipfile, zlib
import xml.etree.ElementTree as ET

BLOCK = 65536
ROOT_URL = 'https://www.microsoft.com/pki/certs/MicRooCerAut2011_2011_03_22.crt'
ROOT_SHA256 = '847df6a78497943f27fc72eb93f9a637320a02b561d0a91b09e87a7807ed7c61'  # Microsoft Root Certificate Authority 2011
SIGNER = 'subject=CN=53C885CA-F222-4EEC-A143-BCF2235F0860'  # the Store's signing name for Salaat First's publisher


class Seekable(io.RawIOBase):
    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        self.pos = (off, self.pos + off, self.size + off)[whence]; return self.pos


class Remote(Seekable):
    """A file on an HTTP server, read with range requests over one kept-alive connection."""
    def __init__(self, url):
        self.url, self.conn, self.pos, self.requests, self.bytes = urllib.parse.urlsplit(url), None, 0, 0, 0
        r = self.request('HEAD', {}); r.read()
        self.size = int(r.getheader('Content-Length'))

    def request(self, method, headers):
        for attempt in range(3):
            try:
                if self.conn is None:
                    cls = http.client.HTTPSConnection if self.url.scheme == 'https' else http.client.HTTPConnection
                    self.conn = cls(self.url.netloc, timeout=60)
                self.conn.request(method, self.url.path + '?' + self.url.query, headers=headers)
                return self.conn.getresponse()
            except (OSError, http.client.HTTPException):
                self.conn = None
                if attempt == 2: raise

    def range(self, start, end):  # a stream of bytes [start, end)
        r = self.request('GET', {'Range': f'bytes={start}-{end - 1}'})
        if r.status != 206 or int(r.getheader('Content-Length')) != end - start:
            raise IOError(f'range request failed: HTTP {r.status}')
        self.requests += 1; self.bytes += end - start
        return r

    def readinto(self, b):
        n = min(len(b), self.size - self.pos)
        if n <= 0: return 0
        b[:n] = self.range(self.pos, self.pos + n).read(); self.pos += n
        return n


class Local(io.FileIO):
    requests = bytes = 0
    def range(self, start, end): self.seek(start); return self


class Window(Seekable):
    """Bytes [off, off + size) of another file: one package inside the bundle."""
    def __init__(self, f, off, size): self.f, self.off, self.size, self.pos = f, off, size, 0
    def readinto(self, b):
        n = min(len(b), self.size - self.pos)
        if n <= 0: return 0
        self.f.seek(self.off + self.pos); d = self.f.read(n); b[:len(d)] = d; self.pos += len(d)
        return len(d)


def verify(p7x, blockmap):
    """Checks that Microsoft signed this block map for Salaat First; the block map holds every block's hash."""
    if p7x[:4] != b'PKCX': raise ValueError('not an MSIX signature')
    der = p7x[4:]
    def value(i):  # start and end of the value of the DER element at i
        n = der[i + 1]; i += 2
        if n & 0x80: k = n & 0x7f; n = int.from_bytes(der[i:i + k], 'big'); i += k
        return i, i + n
    s = value(0)[0]                        # ContentInfo
    s = value(value(s)[1])[0]              # skip its type: SignedData, explicitly tagged
    s = value(s)[0]
    s = value(value(value(s)[1])[1])[0]    # skip version and digest algorithms: the signed content
    s = value(value(s)[1])[0]              # skip its type: explicitly tagged SpcIndirectDataContent
    s, e = value(s)
    content = der[s:e]                     # its value is what the signature covers
    if b'AXBM' + hashlib.sha256(blockmap).digest() not in content:
        raise ValueError("the block map doesn't match the package signature")
    root = urllib.request.urlopen(ROOT_URL, timeout=60).read()
    if hashlib.sha256(root).hexdigest() != ROOT_SHA256: raise ValueError('unexpected Microsoft root certificate')
    with tempfile.TemporaryDirectory() as t:
        p = lambda n: os.path.join(t, n)
        for name, data in ('sig', der), ('content', content), ('root', ssl.DER_cert_to_PEM_cert(root).encode()):
            with open(p(name), 'wb') as f: f.write(data)
        # Store certificates last 3 days and Windows trusts the signature's timestamp instead, which openssl
        # can't check; the leaf also has a critical Microsoft-only extension.
        r = subprocess.run(['openssl', 'smime', '-verify', '-inform', 'DER', '-binary', '-in', p('sig'), '-content', p('content'),
                            '-CAfile', p('root'), '-purpose', 'any', '-no_check_time', '-ignore_critical',
                            '-signer', p('signer'), '-out', os.devnull], capture_output=True, text=True)
        if r.returncode: raise ValueError('bad package signature: ' + r.stderr.strip())
        subject = subprocess.run(['openssl', 'x509', '-in', p('signer'), '-noout', '-subject', '-nameopt', 'RFC2253'],
                                 check=True, capture_output=True, text=True).stdout.strip()
    if subject != SIGNER: raise ValueError(f'signed by {subject}, not by Salaat First')


def main(src, olddir, out):
    f = Remote(src) if src.startswith(('http://', 'https://')) else Local(src)
    z = zipfile.ZipFile(io.BufferedReader(f, BLOCK))
    base = 0
    if 'AppxMetadata/AppxBundleManifest.xml' in z.namelist():
        x64 = [p for p in ET.fromstring(z.read('AppxMetadata/AppxBundleManifest.xml')).iterfind('.//{*}Package')
               if p.get('Type') == 'application' and p.get('Architecture') == 'x64']
        if len(x64) != 1: raise ValueError('no x64 package in the bundle')
        base = int(x64[0].get('Offset'))
        z = zipfile.ZipFile(io.BufferedReader(Window(f, base, int(x64[0].get('Size'))), BLOCK))
    blockmap = z.read('AppxBlockMap.xml')
    verify(z.read('AppxSignature.p7x'), blockmap)
    entries = {urllib.parse.unquote(i.filename): i for i in z.infolist()}  # zip names are URL-encoded

    old = {}  # block hash -> (file, offset), for every block under OLD
    for d, _, names in os.walk(olddir):
        for n in names:
            with open(os.path.join(d, n), 'rb') as g:
                for off in range(0, os.fstat(g.fileno()).st_size, BLOCK):
                    old.setdefault(hashlib.sha256(g.read(BLOCK)).digest(), (os.path.join(d, n), off))

    todo, total = [], 0  # todo: (offset in src, compressed size, deflated?, hash, output file, offset in it)
    for file in ET.fromstring(blockmap).iterfind('{*}File'):
        name, size = file.get('Name'), int(file.get('Size'))
        parts = name.split('\\')
        if not (parts[0] == 'app' or parts[0] == 'bin' and name.endswith('.exe')): continue
        if '..' in parts or '' in parts: raise ValueError(f'bad file name {name}')
        zi = entries[name.replace('\\', '/')]
        path = os.path.join(out, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        pos = base + zi.header_offset + int(file.get('LfhSize'))
        with open(path, 'wb') as g:
            g.truncate(size)
            for i, b in enumerate(file.iterfind('{*}Block')):
                h, n = base64.b64decode(b.get('Hash')), min(BLOCK, size - i * BLOCK)
                csize = int(b.get('Size', n))  # absent when the file is stored uncompressed
                total += 1
                if h in old:
                    with open(old[h][0], 'rb') as o: o.seek(old[h][1]); g.seek(i * BLOCK); g.write(o.read(n))
                else:
                    todo.append((pos, csize, zi.compress_type == zipfile.ZIP_DEFLATED, h, path, i * BLOCK))
                pos += csize

    # One request per run of needed blocks; gaps up to a block are downloaded and skipped.
    i = 0
    while i < len(todo):
        j = i + 1
        while j < len(todo) and todo[j][0] - (todo[j - 1][0] + todo[j - 1][1]) <= BLOCK: j += 1
        r, at = f.range(todo[i][0], todo[j - 1][0] + todo[j - 1][1]), todo[i][0]
        for pos, csize, deflated, h, path, off in todo[i:j]:
            r.read(pos - at)
            data = r.read(csize); at = pos + csize
            if deflated: data = zlib.decompressobj(-15).decompress(data)  # each block is flushed separately
            if hashlib.sha256(data).digest() != h: raise ValueError(f'block {off // BLOCK} of {path} is corrupt')
            with open(path, 'r+b') as g: g.seek(off); g.write(data)
        i = j
    print(f'Reused {total - len(todo)} of {total} blocks, downloaded {f.bytes / 1e6:.1f} MB in {f.requests} requests')


if __name__ == '__main__':
    if len(sys.argv) != 4: sys.exit(__doc__)
    main(*sys.argv[1:])
