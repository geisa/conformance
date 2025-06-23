[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# GEISA Conformance - a GEISA validation framework

GEISA conformance is designed to help developers to validate the conformance
with [GEISA specifications](https://github.com/geisa/specification)

## Usage

### Launch tests automatically

#### Requirements

The automatic test launcher requires the following requirements:
* On the target:
  - Board with a connexion to the network
  - SSH access to the board
* On the host:
  - sshpass (On ubuntu, install with `sudo apt install sshpass`)
  - python3 (On ubuntu, install with `sudo apt install python3`)
  - python3-junitparser (On ubuntu, install with `sudo apt install python3-junitparser`)
  - asciidoctor-pdf (On ubuntu, install with `sudo apt install ruby-asciidoctor-pdf`)

#### Launch tests

A script is provided to launch all tests automatically. This script will execute
the tests and create a report.

``./launch_conformance_tests.sh --ip <board_ip> [options]``

Required options:

* `--ip <board_ip>`: IP address of the board to test

Optional options:

* `--user <username>`: The username for SSH connection (default: root)
* `--password <password>`: The password for SSH connection (default: empty)
* `--help`: display help message

A xml and pdf report will be generated in the `reports` directory.

### Launch tests manually

//TODO

## Testing

Static test is provided to validate the code of conformance tests.

### Run the test via CQFD

#### Requirements

Install cqfd, see [requirements](https://github.com/savoirfairelinux/cqfd?tab=readme-ov-file#requirements) and [installation](https://github.com/savoirfairelinux/cqfd?tab=readme-ov-file#installingremoving-cqfd) on github

#### Run the test

Run the following command to execute the static test:

```bash
$ cqfd init
$ cqfd run
```

### Run the test manually

#### Requirements

The following requirements are needed to run the static test manually:
* shellcheck (On ubuntu, install with `sudo apt install shellcheck`)

#### Run the test

Run the following command to execute the static test:

```bash
$ shellcheck -o all launch_conformance_tests.sh
```
