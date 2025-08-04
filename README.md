[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# GEISA Conformance - a GEISA validation framework

GEISA conformance is designed to help developers to validate the conformance
with [GEISA specifications](https://github.com/geisa/specification)

## Usage

### Launch tests automatically

#### Requirements

The automatic test launcher requires the following requirements:
* On the target:
  * With ssh:
     - Board with a connexion to the network
     - SSH access to the board
     - iperf3 for the bandwidth test
  * With serial:
     - Serial connection to the board
     - lrzsz package
* On the host:
  * With ssh:
     - sshpass (On ubuntu, install with `sudo apt install sshpass`)
     - iperf3 for the bandwidth test (On ubuntu, install with `sudo apt install iperf3`)
  * With serial:
     - python3 (On ubuntu, install with `sudo apt install python3`)
     - pyserial (On ubuntu, install with `sudo apt install python3-serial`)
     - pexpect (On ubuntu, install with `sudo apt install python3-pexpect`)
     - lrzsz (On ubuntu, install with `sudo apt install lrzsz`)
  * For report generation:
    - python3 (On ubuntu, install with `sudo apt install python3`)
    - python3-junitparser (On ubuntu, install with `sudo apt install python3-junitparser`)
    - asciidoctor-pdf (On ubuntu, install with `sudo apt install ruby-asciidoctor-pdf`)

A docker support is also available to launch the tests with a container, it requires:
  - cqfd (See [requirements](https://github.com/savoirfairelinux/cqfd?tab=readme-ov-file#requirements) and [installation](https://github.com/savoirfairelinux/cqfd?tab=readme-ov-file#installingremoving-cqfd) steps on github)

#### Launch tests

A script is provided to launch all tests automatically. This script will execute
the tests and create a report.

``./launch_conformance_tests.sh [options]``

Required options:

* `--ip <board_ip>`: IP address of the board to test
or
* `--serial <serial_port>`: Serial port of the board to test

:Warning: When using serial, do not use another tool to access the serial port
while running the tests, as it may interfere with the tests and cause unexpected
results.

Optional options:

* `--user <username>`: The username for SSH and serial connection (default: root)
* `--password <password>`: The password for SSH and serial connection (default: empty)
* `--no-reports` : Do not generate test reports (only run tests and display results)
* `--baudrate <baudrate>`: The baudrate for the serial port of the board (default: 115200)
* `--help`: display help message

Environment variables can also be used to configure the script:
* `CONFORMACE_SCP_ARGS`: Additional arguments for the `scp` command
* `CONFORMACE_SSH_ARGS`: Additional arguments for the `ssh` command

A xml and pdf report will be generated in the `reports` directory.

To use the docker support run with the following commands:
```bash
$ cqfd init
$ cqfd run ./launch_conformance_tests.sh --ip <board_ip> [options]
or
$ cqfd run ./launch_conformance_tests.sh --serial <serial_port> [options]
```

Launching the tests with the ip option, will run the bandwidth test.

### Launch tests manually

#### Requirements

The manual launch is requiring some dependencies to generate the report on the host:
* python3 (On ubuntu, install with `sudo apt install python3`)
* python3-junitparser (On ubuntu, install with `sudo apt install python3-junitparser`)
* asciidoctor-pdf (On ubuntu, install with `sudo apt install ruby-asciidoctor-pdf`)

A docker support is also available to generate the report on the host, it requires:
* cqfd (See [requirements](https://github.com/savoirfairelinux/cqfd?tab=readme-ov-file#requirements) and [installation](https://github.com/savoirfairelinux/cqfd?tab=readme-ov-file#installingremoving-cqfd) steps on github)

For the tests to run, you need to have the following requirements on the target:
- iperf3 for the bandwidth test (iperf3 should also be installed on the host)

#### Launch tests

If you want to launch the tests manually, you can transfer the tests (src/cukinia-tests) and the orchestrator (src/cukinia) folders to /tmp/conformance_tests folder on the target.

Then on the target, you can run the tests with the following command:

```bash
$ /tmp/conformance_tests/cukinia/cukinia -f junitxml -o geisa-conformance-report.xml /tmp/conformance_tests/cukinia-tests/cukinia.conf
```
This will generate a `geisa-conformance-report.xml` file in the current directory. This file will be used to generated the PDF report.
If you only want to run the tests without generating the report, you can run the following command:

```bash
$ /tmp/conformance_tests/cukinia/cukinia /tmp/conformance_tests/cukinia-tests/cukinia.conf
```

A special case is done for the bandwidth test, as it requires a server to run the test. You can run the following command to launch the tests and generate the report:
```bash
$ /tmp/conformance_tests/cukinia/cukinia -f junitxml -o geisa-conformance-report-bandwidth.xml /tmp/conformance_tests/cukinia-tests/connectivity_tests_bandwidth.conf
```
or without the report generation:
```bash
$ /tmp/conformance_tests/cukinia/cukinia /tmp/conformance_tests/cukinia-tests/connectivity_tests_bandwidth.conf
```

Then on your host you can run the iperf3 client:
```bash
$ iperf3 -c <board_ip>
```

#### Generate report

To generate the PDF report, transfer the xml report (and the bandwidth report if generated) on your host in test-report-pdf folder (/path/to/conformance/src/test-report-pdf) and generate it with the following commands:

```bash
cd /path/to/conformance/src/test-report-pdf
./compile.py -i . -p 'GEISA conformance tests' -d ../pdf_themes
```

This will generate a PDF report in the current directory named `test-report.pdf`.

or you can use the docker support to generate the report on the host with the following commands:

```bash
$ cd /path/to/conformance/
$ cqfd init
$ cqfd run "cd src/test-report-pdf && ./compile.py -i . -p 'GEISA conformance tests' -d ../pdf_themes"
```

This will generate a PDF report in the test-report-pdf directory named `test-report.pdf`.


## Configuration file

A configuration file is provided to set some test checks as the specification are not yet finalized.
The configuration file is located in `src/cukinia-tests/tests_configuration.conf`.

Here are the available configuration options:
* CONFIGURATION_FILE: Used to test the proper functioning of the configuration file.

## Installation

Download the repository and run the following command to download the
dependencies:

```bash
$ git submodule update --init --recursive
```

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
* pylint (On ubuntu, install with `sudo apt install pylint`)
* black (On ubuntu, install with `sudo apt install black`)

#### Run the test

Run the following command to execute the static test:

```bash
$ shellcheck -xo all launch_conformance_tests.sh src/launch_conformance_tests_ssh.sh
$ pylint src/launch_conformance_tests_serial.py
$ black --check --diff src/launch_conformance_tests_serial.py
```
