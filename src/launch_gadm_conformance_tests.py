"""
GEISA Application & Device Management Conformance Launch script.
Copyright (C) 2026 Southern California Edison

GEISA Conformance is free software, distributed under the Apache License
version 2.0. See LICENSE for details.

This script is called by the shell-side conformance launcher to send a single
ADM command (read, write, execute, or push) to a registered LwM2M client via
the Leshan server HTTP API.  It exits with 0 on success or 1 on failure.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

from pathlib import Path

# Supported ADM operations, each mapped to a Leshan HTTP API call.
COMMANDS = ["push", "read", "write", "execute"]


def _parse_response_body(body):
    """Decode JSON responses and preserve raw bodies otherwise."""
    if not body:
        return None
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body


class GadmConformanceTest:
    """GEISA ADM conformance test runner."""

    def __init__(self):
        self.api_endpoint = None
        self.client_name = None
        self.object_uri = None
        self.expected_key = None
        self.expected_value = None
        self.package_path = None
        self.payload = None

    @staticmethod
    def _build_url(api_endpoint, client_name, object_uri, fmt, timeout=5):
        return (
            f"{api_endpoint}/clients/{client_name}/{object_uri}"
            f"?timeout={timeout}&format={fmt}"
        )

    @staticmethod
    def _get_value(response, key_path):
        """Resolve a dot-separated key path in a nested dict/JSON object."""
        value = response
        for key in key_path.split("."):
            if not isinstance(value, dict) or key not in value:
                return None
            value = value[key]
        return value

    @staticmethod
    def _api_request(method, url, timeout, payload=None):
        """Send an HTTP request and decode the JSON response when possible."""
        data = None
        headers = {}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(url, data=data, headers=headers, method=method)

        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8")
                return response.status, _parse_response_body(body)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8")
            return error.code, _parse_response_body(body)

    def _check_response(self, status, response):
        """Validate the API response against expected key/value."""
        if status != 200:
            return False
        value = self._get_value(response, self.expected_key)
        if value is None:
            return False
        actual = str(value).lower()
        expected = str(self.expected_value).lower()
        if actual != expected:
            return False
        return True

    def test_read(self):
        """Read a resource through the Leshan HTTP API."""
        url = GadmConformanceTest._build_url(
            self.api_endpoint, self.client_name, self.object_uri, "TEXT"
        )
        status, response = GadmConformanceTest._api_request("GET", url, timeout=5)
        return self._check_response(status, response)

    def test_write(self):
        """Write a resource through the Leshan HTTP API."""
        url = GadmConformanceTest._build_url(
            self.api_endpoint, self.client_name, self.object_uri, "TEXT"
        )
        status, response = GadmConformanceTest._api_request(
            "PUT", url, timeout=5, payload=self.payload
        )
        return self._check_response(status, response)

    def test_execute(self):
        """Execute a resource through the Leshan HTTP API."""
        url = GadmConformanceTest._build_url(
            self.api_endpoint, self.client_name, self.object_uri, "TEXT"
        )
        status, response = GadmConformanceTest._api_request(
            "POST", url, timeout=5, payload=self.payload
        )
        return self._check_response(status, response)

    def test_push(self):
        """Push the application package to the client."""
        if not Path(self.package_path).is_file():
            return False

        # Encode the binary package as a hex string.
        # LwM2M opaque resources are transmitted this way through the Leshan HTTP API.
        package_data = Path(self.package_path).read_bytes().hex()
        payload = {
            "id": 2,
            "kind": "singleResource",
            "value": package_data,
            "type": "opaque",
        }
        url = GadmConformanceTest._build_url(
            self.api_endpoint, self.client_name, self.object_uri, "OPAQUE", 10
        )
        status, response = GadmConformanceTest._api_request(
            "PUT", url, timeout=10, payload=payload
        )
        return self._check_response(status, response)

    def parse_arguments(self):
        """Parse command line arguments and populate instance variables."""
        parser = argparse.ArgumentParser(
            description="GEISA ADM conformance launch script via Leshan HTTP API."
        )
        parser.add_argument(
            "--api-endpoint",
            required=True,
            help="Leshan HTTP API base endpoint",
        )
        parser.add_argument(
            "--client-name",
            required=True,
            help="ADM client name",
        )
        parser.add_argument(
            "--command",
            required=True,
            choices=COMMANDS,
            help="ADM operation to perform.",
        )
        parser.add_argument(
            "--object-uri",
            required=True,
            help="URI of the object to operate on",
        )
        parser.add_argument(
            "--expected-key",
            required=True,
            help="JSON key to check in the response body",
        )
        parser.add_argument(
            "--expected-value",
            required=True,
            help="Expected value for --expected-key",
        )
        parser.add_argument(
            "--package-path",
            default=None,
            help=(
                "Path to the application package squashfs on the host."
                " To be used with the 'push' command."
            ),
        )
        parser.add_argument(
            "--payload",
            default=None,
            help="JSON payload to write to the ADM client. Default is None.",
        )
        args = parser.parse_args()
        self.api_endpoint = args.api_endpoint
        self.client_name = args.client_name
        self.object_uri = args.object_uri
        self.expected_key = args.expected_key
        self.expected_value = args.expected_value
        self.package_path = args.package_path
        self.payload = json.loads(args.payload) if args.payload else None
        return args.command

    def run(self, command):
        """Dispatch and run the configured command."""
        dispatch = {
            "push": self.test_push,
            "read": self.test_read,
            "write": self.test_write,
            "execute": self.test_execute,
        }
        return dispatch[command]()


def main():
    """Main entry point for the conformance test launcher."""
    test = GadmConformanceTest()
    command = test.parse_arguments()

    if command not in COMMANDS:
        print(f"Error: Unsupported command '{command}'", file=sys.stderr, flush=True)
        sys.exit(1)

    try:
        result = test.run(command)
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr, flush=True)
        sys.exit(1)

    sys.exit(0 if result else 1)


if __name__ == "__main__":
    main()
