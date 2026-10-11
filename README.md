# agena

A small Gemini server written in Free Pascal.

It serves virtual hosts over TLS and runs CGI programs, using
[Indy](https://github.com/IndySockets/Indy) for the protocol side and
[TaurusTLS](https://github.com/TaurusTLS-Developers/TaurusTLS) for TLS, supporting
TLS 1.2 and TLS 1.3. TaurusTLS is agena's only TLS backend; the legacy Indy
OpenSSL handler is no longer supported. TaurusTLS itself uses the system
OpenSSL libraries, so this does not remove OpenSSL as a dependency.

## Build

Requirements:

- Free Pascal Compiler (tested with 3.2.2)
- Git, to fetch the submodules
- System OpenSSL libraries compatible with TaurusTLS (tested with OpenSSL 3)

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

The former `USE_TAURUS=0` build option is rejected instead of silently selecting
an unsupported handler.
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

### Configuration examples

Both example configurations are included:

| Setup | Example |
| --- | --- |
| Single host, one document root and certificate | [agena.ini](agena.ini) |
| Multiple virtual hosts, separate roots and certificates | [agena-vhosts.ini](agena-vhosts.ini) |

### Single host

The [agena.ini](agena.ini) example uses the original single-host format:

```ini
[server]
BindAddress = 127.0.0.1
Port = 1965
DocumentRoot = www
Index = index.gmi

[tls]
CertificateFile = cert.pem
PrivateKeyFile = key.pem
RequireTLS13 = false

[cgi]
PathPrefix = /cgi-bin/

[types]
mp3 = audio/mpeg
ogg = audio/ogg
pdf = application/pdf
```

Relative paths are resolved against the directory holding the INI file, so the
config and its `www` tree can be moved together.

The default, `RequireTLS13 = false`, allows TLS 1.2 and negotiates 1.3 when
the client offers it. `true` sets the TaurusTLS minimum to 1.3, but the current
integration test still observes TLS 1.2 being accepted; see Known bugs.

### Virtual hosts

Add a `[vhost:hostname]` section for each site. All hosts share `[server]`'s
listen address and port. For example:

```ini
[server]
BindAddress = 0.0.0.0
Port = 1965

[vhost:norayr.am]
DocumentRoot = /srv/gemini/norayr.am/pub
Index = index.gmi
CertificateFile = /srv/gemini/norayr.am/norayr.am.crt
PrivateKeyFile = /srv/gemini/norayr.am/norayr.am.key

[vhost:սոնա.հայ]
DocumentRoot = /srv/gemini/սոնա.հայ/pub
CertificateFile = /srv/gemini/սոնա.հայ/fullchain.pem
PrivateKeyFile = /srv/gemini/սոնա.հայ/privkey.pem
```

See [agena-vhosts.ini](agena-vhosts.ini) for a complete multiple-host example.
After adjusting its document roots and certificate paths, start it with:

```sh
./build/agena agena-vhosts.ini
```

- `DocumentRoot` is required for each host. Paths are relative to the INI file
  unless absolute.
- `Index` defaults to `[server]`'s `Index`, or `index.gmi`.
- Certificate/key settings can inherit `[tls]`'s `CertificateFile` and
  `PrivateKeyFile`. Each certificate must cover that host's ASCII DNS name.
- `CGIPrefix` inherits `[cgi]`'s `PathPrefix`. An empty value disables CGI for
  that host; CGI receives its selected `SERVER_NAME` and `DOCUMENT_ROOT`.
- Optional `Hostname` overrides the name in the section title. Unicode and
  ASCII/Punycode forms are accepted; duplicates are rejected after conversion.
- TaurusTLS chooses the certificate using TLS SNI. agena routes the Gemini URL
  only when its hostname matches SNI and its port matches the listener. Unknown
  hosts never fall through to another document root. Request denials receive
  `50`; an unknown SNI not covered by any certificate fails the TLS handshake.
- Without SNI, only the first configured host can be served, using its default
  certificate. Wildcards, aliases and per-location rules are not implemented.

Without any `[vhost:...]` sections, the original single-host configuration
continues to work: `[server]` supplies the document root and `[tls]` the keypair.
Once virtual hosts are configured there is no unnamed fallback document root.

#### Internationalized names

`AgenaIDN.pas` is a separate pure-Pascal RFC 3492 Punycode encoder/decoder, with
UTF-8 domain conversion and DNS length/character checks. It needs **no libidn2,
external command, Lazarus package or platform-specific IDN API**. The standard
RTL `Character` unit supplies Unicode case handling; we do not reimplement it.

For example, `սոնա.հայ` becomes `xn--y9a5bft.xn--y9a3aq`. Clients should send
that ASCII form in SNI and the request URL, and certificates must cover it.
Unicode directory names are independent of the hostname conversion.

This is not a complete IDNA2008/UTS46 implementation. Use NFC-normalized names;
the converter does not normalize Unicode or implement contextual/bidirectional
rules. It accepts letters, decimal digits and combining marks (not initially),
plus DNS ASCII characters; emoji, joiners and other symbols are rejected.

### MIME types

`[types]` maps extensions to full Gemini response metadata:

```ini
[types]
mp3 = audio/mpeg
ogg = audio/ogg
jpg = image/jpeg
jpeg = image/jpeg
png = image/png
gif = image/gif
pdf = application/pdf
txt = text/plain; charset=utf-8
```

Extensions are case-insensitive; a leading dot is optional. Configured mappings
override built-ins, while unlisted extensions retain their existing defaults.
Unknown extensions use `application/octet-stream`; extensionless files retain
the legacy `text/plain` behavior. These mappings apply to static files, not CGI
responses that supply their own `Content-Type`.

## Features

- **TLS 1.3**, via TaurusTLS, with TLS 1.2 as the default floor
- Virtual hosts with separate roots, SNI certificates and CGI prefixes
- Unicode/Punycode domain conversion without an external IDN library
- Static files with configurable MIME mappings and built-in defaults
- `/` and directory paths resolving to a configurable index (default `index.gmi`)
- CGI: any path under `PathPrefix` is executed, with a Gemini environment
- Path traversal defence, in one place (`AgenaPaths.ResolveUnderRoot`)
- Correct status codes: `20` for success and `40` for a missing document
- One INI file, with relative paths resolved against it, so the config and its
  `www` tree can be moved together
- Logging to standard output
- Indy and TaurusTLS compiled into one binary; system OpenSSL is still required

## Known bugs

- A CGI program that exits non-zero after producing output can still receive
  status `20` instead of `42`.
- `RequireTLS13 = true` does not reject TLS 1.2 in the current test setup.
  The application sets the minimum version; the cause remains under investigation.

Both are recorded as expected failures in the dcs integration suite.

## Integration tests

The local suite tests virtual-host routing and certificates, Armenian hostnames,
SNI/URL mismatches, separate roots, custom indexes, MIME overrides, CGI settings,
configuration validation and the legacy single-host format:

```sh
make -f Makefile.fpc test
```

It uses temporary certificates/files and loopback sockets only. Requirements
are Python 3, FPC and the `openssl` CLI. The standalone IDN probe is compiled
with range and overflow checks, and its randomized encode/decode cases are
compared with Python's independent Punycode codec. See [tests/README.md](tests/README.md).

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
| `SERVER_NAME` | the selected virtual host's ASCII hostname (URL host in legacy mode) |

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
agena-vhosts.ini      virtual-host configuration example
src/agena.lpr         program: reads config, configures TaurusTLS/SNI, listens
src/Units/AgenaConfig INI parsing and validation
src/Units/AgenaServer request dispatch, static serving
src/Units/AgenaCGI    CGI execution
src/Units/AgenaPaths  URL to filename mapping, traversal defence
src/Units/AgenaMime   extension to metadata
src/Units/AgenaIDN    standalone Punycode and UTF-8 domain conversion
src/Units/AgenaLog    logging
tests/                virtual-host, MIME, configuration and IDN tests
www/                  document root, with the CGI example under cgi-bin/
third_party/          Indy and TaurusTLS submodules
```

The split is by responsibility, so TLS setup and filename resolution each stay
in one place. Proxying and FastCGI remain future features.

## Credits

- [Indy](https://github.com/IndySockets/Indy) — the protocol and networking
  layer. Gemini and Spartan support in Indy is the subject of
  [PR #697](https://github.com/IndySockets/Indy/pull/697).
- [TaurusTLS](https://github.com/TaurusTLS-Developers/TaurusTLS) — TLS 1.3 on
  top of a current OpenSSL, exposed to Indy as an `IOHandler`.
