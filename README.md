[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# GEISA Conformance - a GEISA validation framework

GEISA conformance is designed to help developers to validate the conformance
with [GEISA specifications](https://github.com/geisa/specification)

## Usage

### Launch tests automatically

A script is provided to launch all tests automatically. This script will execute
the tests and create a report.

``./launch_conformance_tests.sh --ip <board_ip> [options]``

Required options:

* `--ip <board_ip>`: IP address of the board to test

Optional options:

* `--user <username>`: The username for SSH connection (default: root)
* `--help`: display help message

### Launch tests manually

//TODO
