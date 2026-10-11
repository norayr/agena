#!/usr/bin/env python3
"""Local virtual-host, MIME and pure-Pascal IDN tests; no external network.

Run `make -f Makefile.fpc test`. Requires Python 3, FPC and the openssl CLI.
The IDN probe is compiled with range/overflow checks into a temporary directory.
"""

from __future__ import annotations

import concurrent.futures
import os
import random
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
BINARY = Path(os.environ.get("AGENA_BIN", PROJECT / "build" / "agena")).resolve()
ARMENIAN = "սոնա.հայ"
ARMENIAN_ASCII = "xn--y9a5bft.xn--y9a3aq"


def write(path: Path, text: str, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    if executable:
        path.chmod(0o755)


class Server:
    def __init__(self, root: Path, config: str):
        root.mkdir(parents=True, exist_ok=True)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            self.port = sock.getsockname()[1]
        ini = root / "agena.ini"
        ini.write_text(config.replace("@PORT@", str(self.port)), encoding="utf-8")
        self.log_path = root / "server.log"
        self.log = self.log_path.open("w")
        self.process = subprocess.Popen(
            [str(BINARY), str(ini)], cwd=root.parent,
            stdout=self.log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(self.log_path.read_text())
                try:
                    with socket.create_connection(("127.0.0.1", self.port), timeout=0.2):
                        return
                except OSError:
                    time.sleep(0.05)
            raise RuntimeError("server did not start: " + self.log_path.read_text())
        except BaseException:
            self.stop()
            raise

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.log.close()

    def fetch(self, host: str, path: str = "/", *, sni: str | None = None,
              no_sni: bool = False, port: int | None = None,
              verify: bool = False) -> tuple[bytes, bytes, bytes]:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        if verify:
            for cert in CERTS:
                ctx.load_verify_locations(cafile=str(cert))
        else:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
            with ctx.wrap_socket(sock, server_hostname=None if no_sni else (sni or host)) as tls:
                certificate = tls.getpeercert(binary_form=True)
                url = f"gemini://{host}:{self.port if port is None else port}{path}\r\n"
                tls.sendall(url.encode("utf-8"))
                data = bytearray()
                while chunk := tls.recv(16384):
                    data.extend(chunk)
        header, body = bytes(data).split(b"\r\n", 1)
        return header, body, certificate


class IDNTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="agena-idn-")
        cls.probe = Path(cls.directory.name) / "idn_probe"
        subprocess.run(
            [os.environ.get("FPC", "fpc"), "-Mdelphi", "-Cr", "-Co", "-O1",
             "-Fu" + str(PROJECT / "src" / "Units"), "-FU" + cls.directory.name,
             "-FE" + cls.directory.name, str(PROJECT / "tests" / "idn_probe.pas")],
            check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def convert(self, cases: list[tuple[str, str | bytes]]) -> list[bytes]:
        data = b"".join(mode.encode() + b"\t" +
                        (value.encode("utf-8") if isinstance(value, str) else value) + b"\n"
                        for mode, value in cases)
        result = subprocess.run([str(self.probe)], input=data, capture_output=True,
                                check=True, timeout=15)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), len(cases))
        return lines

    def test_known_domains_and_case(self):
        pairs = [(ARMENIAN, ARMENIAN_ASCII), ("ՍՈՆԱ.ՀԱՅ", ARMENIAN_ASCII),
                 ("NORAYR.AM.", "norayr.am"), ("bücher.example", "xn--bcher-kva.example"),
                 ("faß.de", "xn--fa-hia.de"), ("例え.テスト", "xn--r8jz45g.xn--zckzah"),
                 ("www." + ARMENIAN, "www." + ARMENIAN_ASCII)]
        outputs = self.convert([("ascii", name) for name, _ in pairs])
        self.assertEqual(outputs, [b"OK\t" + encoded.encode() for _, encoded in pairs])

    def test_domain_round_trips(self):
        names = [ARMENIAN, "bücher.example", "faß.de", "例え.テスト", "norayr.am"]
        encoded = [line[3:] for line in self.convert([("ascii", name) for name in names])]
        decoded = self.convert([("unicode", name) for name in encoded])
        self.assertEqual(decoded, [b"OK\t" + name.encode() for name in names])

    def test_raw_vectors_and_non_bmp(self):
        names = ["abc", "bücher", "mañana", "սոնա", "հայ", "日本語", "россия",
                 "παράδειγμα", "مثال", "דוגמה", "தமிழ்", "😀", "a𐐀𐐨z", ""]
        expected = [name.encode("punycode") for name in names]
        self.assertEqual(self.convert([("encode", name) for name in names]),
                         [b"OK\t" + value for value in expected])
        self.assertEqual(self.convert([("decode", value) for value in expected]),
                         [b"OK\t" + name.encode() for name in names])

    def test_randomized_against_python_codec(self):
        rng = random.Random(697)
        alphabet = "abcXYZ012-սոնահայäöüßπαράδειγμα日本語😀𐐀𐐨"
        names = ["".join(rng.choice(alphabet) for _ in range(rng.randrange(1, 45)))
                 for _ in range(2000)]
        expected = [name.encode("punycode") for name in names]
        self.assertEqual(self.convert([("encode", name) for name in names]),
                         [b"OK\t" + value for value in expected])
        self.assertEqual(self.convert([("decode", value) for value in expected]),
                         [b"OK\t" + name.encode() for name in names])

    def test_unicode_scalar_boundaries(self):
        names = [chr(value) for value in [0x80, 0x7ff, 0x800, 0xd7ff, 0xe000,
                                         0xffff, 0x10000, 0x10ffff]]
        names += ["a" + name + "z" for name in names]
        expected = [name.encode("punycode") for name in names]
        # Feed UnicodeString scalars directly: FPC's UTF8Decode replaces BMP
        # noncharacters U+FFFE/U+FFFF, independently of the Punycode encoder.
        cases = [("encode32", ",".join(f"{ord(c):x}" for c in name)) for name in names]
        self.assertEqual(self.convert(cases),
                         [b"OK\t" + value for value in expected])
        self.assertEqual(self.convert([("decode", value) for value in expected]),
                         [b"OK\t" + name.encode() for name in names])

    def test_random_malformed_ace_never_crashes(self):
        rng = random.Random(1965)
        names = ["xn--" + "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789-")
                                 for _ in range(rng.randrange(1, 65))) for _ in range(1000)]
        lines = self.convert([("ascii", name) for name in names])
        for result in lines:
            self.assertTrue(result.startswith((b"OK\t", b"ERROR\t")), result)

    def test_malformed_names_and_utf8(self):
        names = ["", ".", "a..am", "a.am..", "-a.am", "a-.am", "a_b.am",
                 "a b.am", "a/b.am", "a:1965", "ab--cd.am", "xn--", "xn--abc-",
                 "xn--a.am", "xn--9" + "9" * 40, "😀.am", "\u0301a.am",
                 b"\xff.am", b"\xc0\xaf.am", b"\xed\xa0\x80.am",
                 b"\xf4\x90\x80\x80.am", b"\xd5.am", b"abc\0.am"]
        for name, output in zip(names, self.convert([("ascii", name) for name in names])):
            with self.subTest(name=name):
                self.assertTrue(output.startswith(b"ERROR\t"), output)

    def test_dns_limits(self):
        valid = "a" * 63
        domain = ".".join([valid, valid, valid, "a" * 61])
        self.assertEqual(len(domain), 253)
        cases = [valid, valid + "a", domain, domain + "a", "ս" * 60]
        lines = self.convert([("ascii", name) for name in cases])
        self.assertTrue(lines[0].startswith(b"OK\t"))
        self.assertTrue(lines[1].startswith(b"ERROR\t"))
        self.assertTrue(lines[2].startswith(b"OK\t"))
        self.assertTrue(lines[3].startswith(b"ERROR\t"))
        self.assertTrue(lines[4].startswith(b"ERROR\t"))

    def test_bad_punycode_is_rejected(self):
        for result in self.convert([("decode", name) for name in ["!", "abc$", "9" * 80]]):
            self.assertTrue(result.startswith(b"ERROR\t"), result)


class IntegrationTests(unittest.TestCase):
    def assert_response(self, host, path="/", body=None, meta=b"text/gemini; charset=utf-8", **kwargs):
        header, got_body, cert = VHOSTS.fetch(host, path, **kwargs)
        self.assertEqual(header, b"20 " + meta)
        if body is not None:
            self.assertEqual(got_body, body)
        return cert

    def test_separate_roots(self):
        self.assert_response("one.example", body=b"# first host\n")
        self.assert_response("two.example", body=b"# second host\n")

    def test_sni_selects_certificates(self):
        for host, cert in zip(["one.example", "two.example", ARMENIAN_ASCII], CERTS):
            with self.subTest(host=host):
                got = self.assert_response(host)
                self.assertEqual(got, ssl.PEM_cert_to_DER_cert(cert.read_text()))

    def test_certificates_validate_for_the_requested_name(self):
        for host in ["one.example", "two.example", ARMENIAN_ASCII]:
            self.assert_response(host, verify=True)

    def test_unicode_configuration_matches_punycode_request(self):
        self.assert_response(ARMENIAN_ASCII, body=b"# Armenian host\n")

    def test_case_and_trailing_dot_routing(self):
        self.assert_response("ONE.EXAMPLE", sni="one.example", body=b"# first host\n")
        self.assert_response("one.example.", sni="one.example", body=b"# first host\n")

    def test_custom_index(self):
        self.assert_response("two.example", "/sub/", body=b"# second subdirectory\n")

    def test_empty_path_uses_index(self):
        self.assert_response("two.example", "", body=b"# second host\n")

    def test_unknown_url_host_is_not_a_default_host(self):
        header, body, _ = VHOSTS.fetch("unknown.example", sni="one.example")
        self.assertTrue(header.startswith(b"50 "))
        self.assertEqual(body, b"")

    def test_unknown_matching_sni_and_url_is_not_served(self):
        # This name is in the first certificate's SAN, but not in the config.
        header, body, _ = VHOSTS.fetch("extra.example")
        self.assertTrue(header.startswith(b"50 "))
        self.assertEqual(body, b"")

    def test_unknown_sni_fails_handshake(self):
        with self.assertRaises((ssl.SSLError, ConnectionError)):
            VHOSTS.fetch("unlisted.example")
        self.assert_response("one.example", body=b"# first host\n")

    def test_sni_url_mismatch_is_rejected(self):
        header, body, _ = VHOSTS.fetch("two.example", sni="one.example")
        self.assertTrue(header.startswith(b"50 "))
        self.assertEqual(body, b"")

    def test_mismatched_port_is_rejected(self):
        header, body, _ = VHOSTS.fetch("one.example", port=VHOSTS.port + 1)
        self.assertTrue(header.startswith(b"50 "))
        self.assertEqual(body, b"")

    def test_no_sni_only_serves_first_host(self):
        self.assert_response("one.example", no_sni=True, body=b"# first host\n")
        header, body, _ = VHOSTS.fetch("two.example", no_sni=True)
        self.assertTrue(header.startswith(b"50 "))
        self.assertEqual(body, b"")

    def test_file_is_not_found_in_another_root(self):
        self.assert_response("one.example", "/only-first.gmi", body=b"private to first\n")
        header, body, _ = VHOSTS.fetch("two.example", "/only-first.gmi")
        self.assertTrue(header.startswith(b"40 "))
        self.assertEqual(body, b"")

    def test_traversal_is_denied(self):
        header, body, _ = VHOSTS.fetch("two.example", "/../one/only-first.gmi")
        self.assertTrue(header.startswith(b"40 "))
        self.assertEqual(body, b"")

    def test_mime_overrides_and_case_insensitive_extensions(self):
        self.assert_response("one.example", "/page.txt", meta=b"text/x-example; charset=utf-8", body=b"text\n")
        self.assert_response("two.example", "/movie.MP3", meta=b"audio/mpeg", body=b"audio")
        self.assert_response("one.example", "/asset.custom", meta=b"application/x-agena", body=b"custom")

    def test_default_mime_types_and_unknown_fallback(self):
        for path, meta in [("page.gmi", b"text/gemini; charset=utf-8"),
                           ("file.pdf", b"application/pdf"), ("file.ogg", b"audio/ogg"),
                           ("file.xyz", b"application/octet-stream")]:
            self.assert_response("one.example", "/" + path, meta=meta)

    def test_binary_body_is_unchanged(self):
        self.assert_response("one.example", "/binary.bin", meta=b"application/octet-stream", body=BINARY_BODY)

    def test_cgi_receives_selected_host_and_root(self):
        expected = f"two.example\n{ROOT / 'hosts' / 'two'}\n".encode()
        self.assert_response("two.example", "/scripts/environment", body=expected)

    def test_cgi_can_be_disabled_per_host(self):
        self.assert_response(ARMENIAN_ASCII, "/cgi-bin/static.gmi", body=b"not executable\n")

    def test_legacy_single_host_configuration(self):
        header, body, _ = LEGACY.fetch("localhost")
        self.assertEqual(header, b"20 text/gemini; charset=utf-8")
        self.assertEqual(body, b"# legacy host\n")

    def test_legacy_mime_override(self):
        header, body, _ = LEGACY.fetch("localhost", "/page.TXT")
        self.assertEqual(header, b"20 text/x-legacy; charset=utf-8")
        self.assertEqual(body, b"legacy text\n")

    def test_cgi_prefix_inherited_from_global_section(self):
        expected = f"one.example\n{ROOT / 'hosts' / 'one'}\n".encode()
        self.assert_response("one.example", "/cgi-bin/environment", body=expected)

    def test_concurrent_hosts_do_not_share_state(self):
        hosts = [("one.example", b"# first host\n"), ("two.example", b"# second host\n"),
                 (ARMENIAN_ASCII, b"# Armenian host\n")] * 12
        def request(pair):
            host, body = pair
            self.assert_response(host, body=body)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(request, hosts))


class ConfigurationTests(unittest.TestCase):
    def reject(self, extra: str, message: str):
        config = ROOT / "bad.ini"
        config.write_text("[server]\nBindAddress=127.0.0.1\nPort=1965\n" + extra,
                          encoding="utf-8")
        result = subprocess.run([str(BINARY), str(config)], cwd=ROOT.parent,
                                capture_output=True, timeout=5)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message.encode(), result.stdout + result.stderr)

    def test_duplicate_unicode_and_ace_host(self):
        self.reject(f"[vhost:{ARMENIAN}]\nDocumentRoot=hosts/{ARMENIAN}\n"
                    f"[vhost:{ARMENIAN_ASCII}]\nDocumentRoot=hosts/two\n", "duplicate virtual host")

    def test_invalid_hostname(self):
        self.reject("[vhost:bad_name]\nDocumentRoot=hosts/one\n", "non-DNS character")

    def test_missing_root(self):
        self.reject("[vhost:one.example]\nCertificateFile=one.pem\n", "DocumentRoot is required")

    def test_invalid_index(self):
        self.reject("Index=../secret\n", "Index must be a filename")

    def test_invalid_extension(self):
        self.reject("[types]\ntar.gz=application/gzip\n", "invalid extension")

    def test_duplicate_extension(self):
        self.reject("[types]\n.txt=text/plain\ntxt=text/gemini\n", "duplicate extension")

    def test_invalid_media_type(self):
        self.reject("[types]\ntxt=not-a-media-type\n", "invalid MIME type")

    def test_overlong_metadata(self):
        self.reject("[types]\ntxt=text/plain; x=" + "a" * 1024 + "\n", "invalid MIME metadata")

    def test_certificate_files_checked_for_every_host(self):
        self.reject("[vhost:one.example]\nDocumentRoot=hosts/one\n"
                    f"CertificateFile={CERTS[0]}\nPrivateKeyFile={KEYS[0]}\n"
                    "[vhost:two.example]\nDocumentRoot=hosts/two\n"
                    "CertificateFile=missing.pem\nPrivateKeyFile=missing.key\n",
                    "two.example: certificate not found")


def certificate(root: Path, name: str, extra_name: str = "") -> tuple[Path, Path]:
    root.mkdir(parents=True, exist_ok=True)
    cert, key = root / (name + ".pem"), root / (name + ".key")
    sans = "DNS:" + name + (",DNS:" + extra_name if extra_name else "")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-days", "2", "-subj", "/CN=" + name, "-addext", "subjectAltName=" + sans,
                    "-out", str(cert), "-keyout", str(key)], check=True, capture_output=True)
    return cert, key


if __name__ == "__main__":
    if not BINARY.is_file():
        raise SystemExit("build agena first: make -f Makefile.fpc")
    with tempfile.TemporaryDirectory(prefix="agena-vhosts-") as directory:
        ROOT = Path(directory)
        pairs = [certificate(ROOT / ARMENIAN if i == 2 else ROOT, name,
                             "extra.example" if i == 0 else "")
                 for i, name in enumerate(["one.example", "two.example", ARMENIAN_ASCII])]
        CERTS = [cert for cert, _ in pairs]
        KEYS = [key for _, key in pairs]
        for name, index, title in [("one", "index.gmi", "first"),
                                   ("two", "home.gmi", "second"),
                                   (ARMENIAN, "index.gmi", "Armenian")]:
            write(ROOT / "hosts" / name / index, f"# {title} host\n")
        write(ROOT / "hosts" / "two" / "sub" / "home.gmi", "# second subdirectory\n")
        write(ROOT / "hosts" / "one" / "only-first.gmi", "private to first\n")
        write(ROOT / "hosts" / "one" / "page.txt", "text\n")
        write(ROOT / "hosts" / "one" / "asset.custom", "custom")
        write(ROOT / "hosts" / "two" / "movie.MP3", "audio")
        for name in ["page.gmi", "file.pdf", "file.ogg", "file.xyz"]:
            write(ROOT / "hosts" / "one" / name, "payload\n")
        BINARY_BODY = bytes(range(256)) * 1024
        (ROOT / "hosts" / "one" / "binary.bin").write_bytes(BINARY_BODY)
        for name, prefix in [("one", "cgi-bin"), ("two", "scripts")]:
            write(ROOT / "hosts" / name / prefix / "environment",
                  f"#!{sys.executable}\nimport os\nprint(os.environ['SERVER_NAME'])\n"
                  "print(os.environ['DOCUMENT_ROOT'])\n", executable=True)
        write(ROOT / "hosts" / ARMENIAN / "cgi-bin" / "static.gmi", "not executable\n")

        config = ("[server]\nBindAddress=127.0.0.1\nPort=@PORT@\nIndex=index.gmi\n"
                  f"[tls]\nCertificateFile={CERTS[2]}\nPrivateKeyFile={KEYS[2]}\n"
                  "[cgi]\nPathPrefix=/cgi-bin/\n")
        for i, (host, root, index, prefix) in enumerate([
            ("one.example", "one", "index.gmi", "/cgi-bin/"),
            ("two.example", "two", "home.gmi", "/scripts/"),
            (ARMENIAN, ARMENIAN, "index.gmi", "")]):
            title = "second site" if i == 1 else host
            config += f"[vhost:{title}]\nDocumentRoot={root}\n"
            if i == 1:
                config += f"Hostname={host}\n"
            if i != 0:
                config += f"Index={index}\nCGIPrefix={prefix}\n"
            if i != 2:
                config += f"CertificateFile={CERTS[i]}\nPrivateKeyFile={KEYS[i]}\n"
        config += ("[types]\n.txt=text/x-example; charset=utf-8\nMP3=audio/mpeg\n"
                   "custom=application/x-agena\n")
        VHOSTS = Server(ROOT / "hosts", config)
        try:
            certificate(ROOT, "localhost")
            write(ROOT / "legacy" / "www" / "index.gmi", "# legacy host\n")
            write(ROOT / "legacy" / "www" / "page.TXT", "legacy text\n")
            LEGACY = Server(ROOT / "legacy", "[server]\nBindAddress=127.0.0.1\n"
                            "Port=@PORT@\nDocumentRoot=www\n[tls]\n"
                            "CertificateFile=../localhost.pem\nPrivateKeyFile=../localhost.key\n"
                            "[types]\ntxt=text/x-legacy; charset=utf-8\n")
            try:
                result = unittest.main(verbosity=2, exit=False).result
            finally:
                LEGACY.stop()
        finally:
            VHOSTS.stop()
    raise SystemExit(0 if result.wasSuccessful() else 1)
