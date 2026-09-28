# agena

A small Gemini server written in Free Pascal.

It serves a document root over TLS and runs CGI programs, using
[Indy](https://github.com/IndySockets/Indy) for the protocol side and
[TaurusTLS](https://github.com/TaurusTLS-Developers/TaurusTLS) for TLS, which
gives TLS 1.3 — something Indy's own OpenSSL handler cannot do, since it
targets OpenSSL 1.0.x.

## Build

Requirements:

- Free Pascal Compiler (tested with 3.2.2)
- Git, to fetch the submodules

Indy and TaurusTLS are vendored as submodules and pinned to known-good commits.

```sh
git clone <this repository>
cd agena
git submodule update --init

make -f Makefile.fpc check   # verify fpc and both submodules are present
make -f Makefile.fpc         # build with TaurusTLS (TLS 1.3)
```

The binary lands in `build/agena`.

To build against Indy's own OpenSSL handler instead, which caps out at TLS 1.2:

```sh
make -f Makefile.fpc clean
make -f Makefile.fpc USE_TAURUS=0
```

`make -f Makefile.fpc clean` removes the build directory.

## Run

You need a certificate and private key. agena will not generate one for you:

```sh
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem \
  -days 365 -nodes -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```

Then:

```sh
./build/agena agena.ini
```

The server takes the path to an INI file as its only argument. It logs to
standard output and runs until interrupted.

Certificate and key files are git-ignored, along with the `build` directory, so
generating them locally does not risk committing a private key.

### Configuration

`agena.ini`:

```ini
[server]
BindAddress = 127.0.0.1
Port = 1965
DocumentRoot = www

[tls]
CertificateFile = cert.pem
PrivateKeyFile = key.pem
RequireTLS13 = false

[cgi]
PathPrefix = /cgi-bin/
```

Relative paths are resolved against the directory holding the INI file, so the
config and its `www` tree can be moved together.

`RequireTLS13 = true` refuses TLS 1.2 and offers 1.3 only. The default, `false`,
means 1.2 is the floor and 1.3 is negotiated when the client offers it, which is
what the Gemini specification asks for.

## Supported

- **TLS 1.3**, via TaurusTLS, with TLS 1.2 as the default floor
- Static files under the document root, with a metadata guess by extension
- `/` and any directory path resolving to `index.gmi`
- CGI: any path under `PathPrefix` is executed
- Path traversal defence, in one place (`AgenaPaths.ResolveUnderRoot`)

Responses use the correct status codes: `20` for success and `40` for a missing
document.

## Not supported

Being explicit, because most of the Gemini specification is optional and it is
easy to assume otherwise.

### Known bugs

None currently known.

### Protocol features not implemented

These are all legal Gemini, just not implemented:

- Request input and sensitive input. agena never sends a `10` or `11` status, so
  a client has no reason to send a body. Note that CGI scripts do receive any
  input that happens to arrive, and `REQUEST_METHOD` reflects it.
- Redirects, temporary and permanent
- Client certificates. The server does not request one, so `gsCertRequired` and
  the related statuses are never sent. There is no fingerprint helper either,
  despite Indy having one.
- Temporary and permanent failure statuses, other than as the generic
  not-found response
- Content negotiation via meta alternates

### Operational gaps

- **No timeout on CGI programs.** A script that hangs will tie up its
  connection thread until the client gives up.
- No request logging to a file, and no log rotation. Output goes to stdout, so
  redirect it if you need it kept.
- No caching headers: no `Last-Modified`, `ETag`, or `If-Modified-Since`.
- No directory listings. A directory without an `index.gmi` is a `40`.
- No compression, and no streaming of large files; the whole file is read.
- Signal handling is limited. It runs until interrupted; there is no graceful
  drain of in-flight requests.
- Windows is untested. It should work, since Indy and TaurusTLS both support
  it, but nobody has run it there.
- No test suite, and it has not been committed to any remote yet.

## CGI

A request whose path starts with `PathPrefix` is run as a program under the
document root. It must be executable, and it either needs a working shebang or
has to be a compiled binary.

Standard output is the response body. If the first line is a
`Content-Type: ...` header it is used as the response metadata and stripped
along with the blank line that follows it; otherwise the metadata defaults to
`text/gemini`. Standard input is always closed once any input has been passed
on, so a script is free to read it to the end without blocking.

The environment includes the usual CGI names, plus Gemini-specific ones:

| Variable | Meaning |
| --- | --- |
| `GEMINI_URL` | the full request URL |
| `SERVER_PROTOCOL` | always `GEMINI` |
| `PATH_INFO` | the request path |
| `QUERY_STRING` | the query, if any |
| `REQUEST_METHOD` | `GET`, or `POST` when input was supplied |
| `CONTENT_LENGTH` | length of the input on stdin |
| `REMOTE_ADDR` | peer address |
| `SCRIPT_FILENAME` | resolved script path |
| `DOCUMENT_ROOT` | the configured document root |

Two worked examples ship in `www/cgi-bin`. `hello.py` has a shebang and runs as
is; it echoes back the query string and shows what the environment looks like.
`hello.pas` shows the same thing without needing an interpreter, and is compiled
into place:

```sh
fpc -O2 -o www/cgi-bin/hello www/cgi-bin/hello.pas
```

Note that agena sets the environment explicitly rather than inheriting its own,
so a script that needs `PATH` or `HOME` will not find them. Add them to the
script or extend `AgenaCGI` as needed.

## Layout

```
Makefile.fpc          build
agena.ini             sample configuration
src/agena.lpr         program: reads config, picks a TLS backend, listens
src/Units/AgenaConfig INI parsing and validation
src/Units/AgenaServer request dispatch, static serving
src/Units/AgenaCGI    CGI execution
src/Units/AgenaPaths  URL to filename mapping, traversal defence
src/Units/AgenaMime   extension to metadata
src/Units/AgenaLog    logging
www/                  document root, with the CGI example under cgi-bin/
third_party/          Indy and TaurusTLS submodules
```

The split is by responsibility, so the TLS backend is a choice in one place and
filename resolution is a decision in one place.

## Credits

- [Indy](https://github.com/IndySockets/Indy) — the protocol and networking
  layer. Gemini and Spartan support in Indy is the subject of
  [PR #697](https://github.com/IndySockets/Indy/pull/697).
- [TaurusTLS](https://github.com/TaurusTLS-Developers/TaurusTLS) — TLS 1.3 on
  top of a current OpenSSL, exposed to Indy as an `IOHandler`.
