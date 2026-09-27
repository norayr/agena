#!/usr/bin/env python3
"""A tiny agena CGI example.

Environment variables provided by agena:
  GEMINI_URL, PATH_INFO, QUERY_STRING, REQUEST_METHOD,
  CONTENT_LENGTH, REMOTE_ADDR, SERVER_PROTOCOL, SERVER_PORT

Standard output becomes the response body.  An optional first line of
"Content-Type: <mime>" overrides the response metadata.
"""
import os
import sys

query = os.environ.get("QUERY_STRING", "")
method = os.environ.get("REQUEST_METHOD", "GET")

print("Content-Type: text/gemini; charset=utf-8")
print()
print("# hello from a CGI script")
print()
print(f"asked for {os.environ.get('GEMINI_URL', '?')}")
print(f"method: {method}")

if query:
    print(f"query: {query}")
else:
    print("no query string")
