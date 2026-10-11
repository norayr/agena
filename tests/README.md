# agena tests

```sh
make -f Makefile.fpc test
```

Requirements: Free Pascal, Python 3, the `openssl` CLI and the system OpenSSL
libraries used by TaurusTLS. No IDN library, DNS access or public server is used.

`run_tests.py` generates short-lived self-signed certificates, temporary document
roots and INI files. It connects to agena over loopback TLS and checks:

- IPv6-only and dual-family listeners, wildcard binding in either family order,
  three/five-address mixed lists, IPv6 URL literals and SNI routing on IPv6.
- Duplicate/invalid/overlapping bind addresses, plus startup failure and cleanup
  when a later listener's port is occupied. No network interfaces are modified.
- Different SNI certificates and document roots on the same port, including an
  Armenian hostname configured in UTF-8 and requested in Punycode.
- Hostname/certificate validation, case handling, custom indexes, rejection of
  unknown hosts and SNI/URL or port mismatches, and the no-SNI default-host rule.
- MIME overrides, case-insensitive extensions, built-in defaults and binary data.
- CGI's selected hostname/root and per-host CGI disabling.
- Relative configuration paths, invalid/duplicate settings and concurrent hosts.
- Backward compatibility with the original single-host INI format.

`idn_probe.pas` is compiled independently with `-Cr -Co` into a temporary
directory. Conversion checks cover Armenian and other scripts, DNS limits,
malformed UTF-8/ACE, non-BMP raw Punycode and 2,000 randomized labels compared
against Python's Punycode codec in both directions.

`config_probe.pas` is also compiled with range/overflow checks. It tests bind-list
parsing independently of available interfaces, including a 128-address mixed
list. Socket tests skip with a reason if IPv6 or the additional IPv4 loopback
addresses are unavailable; parsing tests still run on those machines.

`AGENA_BIN=/path/to/agena` selects an existing binary; `FPC=/path/to/fpc` selects
the compiler for the probe. Python unittest filtering also works, for example:

```sh
python3 tests/run_tests.py IDNTests
```

Use `TMPDIR=/tmp/opencode` in the local development environment to keep fixtures
in its approved temporary directory. The existing wider dcs/agena suite remains
in [dcs/tests](https://github.com/norayr/dcs/tree/main/tests); its two documented
known failures are not changed by these features.
