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

Indy and TaurusTLS are vendored as submodules. Indy is pinned to
[`7be08890`](https://github.com/norayr/Indy/commit/7be08890d8b1b2d51e6a6e64384cc908b12a93ed)
in [norayr/Indy](https://github.com/norayr/Indy), the Gemini/Spartan revision
submitted in [PR #697](https://github.com/IndySockets/Indy/pull/697).

```sh
git clone --recurse-submodules https://github.com/norayr/agena.git
cd agena

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

The default, `RequireTLS13 = false`, allows TLS 1.2 and negotiates 1.3 when
the client offers it. `true` sets the TaurusTLS minimum to 1.3, but the current
integration test still observes TLS 1.2 being accepted; see Known bugs.

## Features

- **TLS 1.3**, via TaurusTLS, with TLS 1.2 as the default floor
- Static files under the document root, with a metadata guess by extension
- `/` and any directory path resolving to `index.gmi`
- CGI: any path under `PathPrefix` is executed, with a Gemini environment
- Path traversal defence, in one place (`AgenaPaths.ResolveUnderRoot`)
- Correct status codes: `20` for success and `40` for a missing document
- One INI file, with relative paths resolved against it, so the config and its
  `www` tree can be moved together
- Logging to standard output
- One self-contained binary: Indy and TaurusTLS are vendored and pinned, so
  there is nothing to install alongside it

## Known bugs

- A CGI program that exits non-zero after producing output can still receive
  status `20` instead of `42`.
- `RequireTLS13 = true` does not reject TLS 1.2 in the current test setup.
  The application sets the minimum version; the cause remains under investigation.

Both are recorded as expected failures in the dcs integration suite.

## Integration tests

The [dcs repository](https://github.com/norayr/dcs/tree/main/tests) contains
tests that launch agena with temporary certificates and documents, exercise
the server over raw TLS connections, and fetch from it through dcs.
With the two checkouts next to each other:

```sh
make -f Makefile.fpc
make -C ../dcs -f Makefile.fpc
make -C ../dcs -f Makefile.fpc test AGENA_DIR="$PWD"
```

The reviewed revision produced 53 passes, no unexpected failures, and the two
known failures above. See the suite's README for coverage and filtering options.

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
