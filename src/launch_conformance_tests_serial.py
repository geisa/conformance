"""
GEISA Conformance Launch script for serial-based execution
Copyright (C) 2025 Southern California Edison

GEISA Conformance is free software, distributed under the Apache License
version 2.0. See LICENSE for details.
"""

import argparse
import fcntl
import os
import subprocess
import sys
import tarfile
import time
import pexpect
import pexpect.fdpexpect
import serial

TOPDIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def compress_dir(src_dir, archive_name):
    """
    Compress a directory into a tar.gz archive.
    """
    with tarfile.open(f"{TOPDIR}/{archive_name}", "w:gz") as tar:
        tar.add(src_dir, arcname=os.path.basename(src_dir))


def send_command(command, ser):
    """
    Send a command to the serial port.
    """
    ser.write((command + "\n").encode("utf-8"))
    ser.flush()
    ser.reset_input_buffer()
    ser.reset_output_buffer()
    time.sleep(1)


def send_file_via_zmodem(archive_name, args):
    """
    Send a file via ZMODEM protocol using sz command.
    """
    try:
        with open(args.serial, "rb") as ser_in, open(args.serial, "wb") as ser_out:
            subprocess.run(
                ["sz", archive_name, "--zmodem"],
                stdin=ser_in,
                stdout=ser_out,
                check=True,
            )
    except subprocess.CalledProcessError as e:
        print(f"Error sending file {archive_name} via ZMODEM: {e}")
        sys.exit(-1)


def send_and_uncompress_cukinia_files(ser, args):
    """
    Send and uncompress Cukinia files on the board.
    """
    send_command("cd /tmp && rz -y --zmodem", ser)
    send_file_via_zmodem(f"{TOPDIR}/cukinia.tar.gz", args)
    send_command("cd /tmp && rz -y --zmodem", ser)
    send_file_via_zmodem(f"{TOPDIR}/cukinia-tests.tar.gz", args)

    send_command("mkdir -p conformance_tests", ser)
    send_command("cd /tmp && tar -xzf cukinia.tar.gz -C /tmp/conformance_tests", ser)
    send_command(
        "cd /tmp && tar -xzf cukinia-tests.tar.gz -C /tmp/conformance_tests", ser
    )


def cleanup(ser):
    """
    Clean up the test files on the board.
    """
    send_command(
        "cd /tmp && rm -rf /tmp/conformance_tests /tmp/cukinia.tar.gz /tmp/cukinia-tests.tar.gz",
        ser,
    )


def get_cukinia_report(args, ser):
    """
    Get the Cukinia test report from the board.
    """
    print("Copying tests report on host\n")
    send_command(
        "cd /tmp/conformance_tests/cukinia-tests/ && sz -v geisa-conformance-report.xml --zmodem",
        ser,
    )
    try:
        with open(args.serial, "rb") as ser_in, open(args.serial, "wb") as ser_out:
            subprocess.run(
                ["rz", "-y", "--zmodem"],
                stdin=ser_in,
                stdout=ser_out,
                cwd=f"{TOPDIR}/reports",
                check=True,
            )
    except subprocess.CalledProcessError as e:
        print(f"Error receiving report file via ZMODEM: {e}")
        sys.exit(-1)

    while True:
        sz_output = ser.readline()
        if "Transfer complete" in sz_output.decode("utf-8"):
            break


def print_cukinia_output(ser):
    """
    Print the output of the Cukinia tests from the board.
    """
    ser.readline()
    while True:
        cukinia_output = ser.readline()
        print(cukinia_output.decode("utf-8").strip())
        if "GEISA conformance tests" in cukinia_output.decode("utf-8"):
            break


def get_cukinia_return_code(ser):
    """
    Get the return code of the Cukinia tests from the board.
    """
    send_command("echo $?", ser)
    ser.readline()
    test_exit_code = ser.readline().decode("utf-8").strip()
    return int(test_exit_code)


def launch_cukinia_tests(args, ser):
    """
    Launch Cukinia tests on the board.
    If --no-reports is specified, only run tests and display results without generating reports.
    """
    if args.no_reports:
        send_command(
            "/tmp/conformance_tests/cukinia/cukinia "
            "/tmp/conformance_tests/cukinia-tests/cukinia.conf",
            ser,
        )
        print_cukinia_output(ser)
        test_exit_code = get_cukinia_return_code(ser)
    else:
        send_command(
            "/tmp/conformance_tests/cukinia/cukinia -f junitxml "
            "-o /tmp/conformance_tests/cukinia-tests/geisa-conformance-report.xml "
            "/tmp/conformance_tests/cukinia-tests/cukinia.conf",
            ser,
        )
        test_exit_code = get_cukinia_return_code(ser)
        get_cukinia_report(args, ser)

    return int(test_exit_code)


def parse_arguments():
    """
    Parse command line arguments.
    """
    parser = argparse.ArgumentParser(
        description="GEISA Conformance Launch script via serial connection."
    )
    parser.add_argument(
        "--serial",
        help="Specify the serial port of the board to run tests on",
        required=True,
    )
    parser.add_argument(
        "--baudrate",
        help="Specify the baudrate for the serial port of the board (default: 115200)",
        default="115200",
    )
    parser.add_argument(
        "--user",
        help="Specify the username for SSH connection (default: root)",
        default="root",
    )
    parser.add_argument(
        "--password",
        help="Specify the password for SSH connection (default: empty)",
        default="",
    )
    parser.add_argument(
        "--no-reports",
        action="store_true",
        help="Do not generate test reports (only run tests and display results)",
        default=False,
    )
    args = parser.parse_args()
    return args


def detect_board_state(p, args):
    """
    Detect the board state by sending a command and checking the response.
    """

    try:
        print("Detecting board state...\n")
        p.sendline("\n")
        i = p.expect([r"(\S*)@\S*:.+(#|\$)", r"login:"])
        if i == 1:
            p.sendline(args.user)
            i = p.expect([r"Password:", r"(\S*)@\S*:.+(#|\$)"])
            if i == 0:
                if not args.password:
                    print("Error: Password is required for login.")
                    sys.exit(-1)
                p.sendline(args.password)
                i = p.expect([r"(\S*)@\S*:.+(#|\$)", r"Login incorrect"])
                if i == 1:
                    print("Error: Failed to login, check your credentials.")
                    sys.exit(-1)

        print("Login successful\n")

    except pexpect.exceptions.TIMEOUT:
        print("Warning: enable to detect board state, continuing anyway\n")


def main():
    """
    Main function.
    """
    args = parse_arguments()

    compress_dir(f"{TOPDIR}/src/cukinia", "cukinia.tar.gz")
    compress_dir(f"{TOPDIR}/src/cukinia-tests", "cukinia-tests.tar.gz")

    try:
        with serial.Serial(args.serial, args.baudrate, timeout=1) as ser:
            fcntl.flock(ser.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            p = pexpect.fdpexpect.fdspawn(ser, timeout=5)

            detect_board_state(p, args)

            print("Cleaning previous test results on board\n")
            cleanup(ser)

            print("Copying conformance test files to board\n")
            send_and_uncompress_cukinia_files(ser, args)

            print("Launching tests...\n")
            test_exit_code = launch_cukinia_tests(args, ser)

            print("Cleaning up test files on board\n")
            cleanup(ser)

    except serial.SerialException as e:
        print(f"Error when executing serial command: {e}\n")
        sys.exit(-1)
    except BlockingIOError:
        print(f"Serial port {args.serial} is already in use!")
        sys.exit(-1)
    except pexpect.EOF:
        print(
            "Error: Unexpected end of file from serial port. Verify "
            "that the serial port is not already in use.\n"
        )
        sys.exit(-1)
    except Exception as e:  # pylint: disable=broad-exception-caught
        print(f"An unexpected error occurred: {e}\n")
        sys.exit(-1)

    sys.exit(test_exit_code)


if __name__ == "__main__":
    main()
