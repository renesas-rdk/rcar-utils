#!/usr/bin/python3

# Imports
import serial
import argparse
import time
import os
import subprocess
import glob
from subprocess import Popen, PIPE, CalledProcessError
import platform
from serial.tools.list_ports import comports
import sys
if sys.version_info >= (3, 11):  # pragma: Python version >=3.11
    import tomllib
else:  # pragma: Python version <3.11
    import tomli as tomllib

DEFAULT_FASTBOOT_SERIAL = "Renesas_RZ_CMN"


# Constants
SERIAL_RECONNECT_TIMEOUT = 30
WAIT_POWER_TIMEOUT = 120
SERIAL_RECONNECT_CHECK_INTERVAL = 0.1
SERIAL_READ_TIMEOUT = 10
SERIAL_READ_BUFFER_SIZE = 4096
DEVICE_READY_WAIT = 0.2
BUFFER_CLEAR_WAIT = 0.5
BUFFER_CHECK_WAIT = 0.3
BUFFER_CHECK_TIMEOUT = 5
MAX_RECONNECT_RETRIES = 3
SEPARATOR_WIDTH = 85
SERIAL_BY_ID_DIR = "/dev/serial/by-id"

class SdFlashUtil:
	def __init__(self, args=None):
		self.__scriptDir = os.path.dirname(os.path.abspath(__file__))
		self.__rootDir = os.path.abspath(os.path.join(self.__scriptDir, '..', '..', '..'))
		self.__imagesDir = os.path.abspath(os.path.join(self.__rootDir, 'target', 'images'))
		self.__fastbootDevice = DEFAULT_FASTBOOT_SERIAL
		self.__oldPort = None

		if platform.system() == "Windows":
			self.__fastboot = os.path.abspath(os.path.join(self.__scriptDir, 'tools', 'fastboot.exe'))
		elif platform.system() == "Linux":
			self.__fastboot = "fastboot"

		self.__setupArgumentParser(args)
		self.__setupSerialPort()

	# Setup CLI parser
	def __setupArgumentParser(self, args):
		# Create parser
		self.__parser = argparse.ArgumentParser(description='Utility to flash WIC image on RZ and R-Car boards.\n', epilog='Example:\n\t./sd_flash.py')

		# Add arguments
		# Board name
		self.__parser.add_argument('--board_name',
									default='rzg2l-sbc',
									dest='boardName',
									action='store',
									type=str,
									help='Board name to flash bootloader (defaults to: rzg2l-sbc).')

		# Fastboot arguments
		self.__parser.add_argument('--fastboot_type',
									default='udp',
									dest='fastbootType',
									action='store',
									type=str,
									choices=['otg', 'udp'],
									help='Fastboot type to use (defaults to: udp).')
		self.__parser.add_argument('--ether_port',
									default=1,
									dest='etherPort',
									action='store',
									type=int,
									help='[Only used in fastboot UDP] Ethernet port used to board communication (defaults to: 1).')
		self.__parser.add_argument('--ip_address',
									default="169.254.187.89",
									dest='ipAddress',
									action='store',
									type=str,
									help='[Only used in fastboot UDP] Ethernet IP address used to board communication (defaults to: 169.254.187.89).')

		# Serial port arguments
		self.__parser.add_argument('--serial_port',
									default=None,
									dest='serialPort',
									action='store',
									help='Serial port used to talk to board (defaults to: most recently connected port).')
		self.__parser.add_argument('--serial_port_by_id',
									default=None,
									dest='serialPortById',
									action='store',
									help='Serial port by-id path for reliable reconnection (e.g., /dev/serial/by-id/...).')
		self.__parser.add_argument('--serial_port_baud',
									default=115200,
									dest='baudRate',
									action='store',
									type=int,
									help='Baud rate for serial port (defaults to: 115200).')

		# Images
		self.__parser.add_argument('--image_rootfs',
									default=f'{self.__imagesDir}/core-image-minimal.wic',
									dest='rootfsImage',
									action='store',
									type=str,
									help='Path to rootfs (defaults to: <path/to/your/package>/target/images/core-image-minimal.wic).')

		if args:
			self.__args = self.__parser.parse_args(args)
		else:
			self.__args = self.__parser.parse_args()

	# Setup Serial Port
	def __setupSerialPort(self):
		try:
			# Store the by-id path if provided
			self.__serialPortById = getattr(self.__args, 'serialPortById', None)

			if (self.__args.serialPort is None):
				ports = [port.device for port in comports()]
				print(f"Available serial ports: {ports}")
				print(f"Using serial port: {ports[0]}")
				self.__serialPortPath = ports[0]
				self.__serialPort = serial.Serial(port=ports[0], baudrate=self.__args.baudRate, timeout=15)
			else:
				self.__serialPortPath = self.__args.serialPort
				self.__serialPort = serial.Serial(port=self.__args.serialPort, baudrate=self.__args.baudRate, timeout=15)

			# Store old port session
			self.__oldPort = self.__serialPortPath

			# If no by-id path provided, try to resolve it
			if not self.__serialPortById:
				self.__serialPortById = self._get_by_id_path(self.__serialPortPath)

		except:
			die(msg='Unable to open serial port.')

	def _get_by_id_path(self, tty_device: str) -> str:
		"""Get the /dev/serial/by-id/ path for a given tty device."""
		if not os.path.exists(SERIAL_BY_ID_DIR):
			return tty_device

		device_name = os.path.basename(tty_device)

		try:
			for by_id_link in glob.glob(os.path.join(SERIAL_BY_ID_DIR, "*")):
				real_path = os.path.realpath(by_id_link)
				if os.path.basename(real_path) == device_name:
					return by_id_link
		except Exception as e:
			print(f"Warning: Could not resolve by-id path: {e}")

		return tty_device

	def _wait_for_serial_reconnect(self, timeout: int = SERIAL_RECONNECT_TIMEOUT) -> bool:
		"""Wait for serial port to reconnect after power cycle."""

		start_time = time.time()
		last_print_time = 0

		while (time.time() - start_time) < timeout:
			elapsed = time.time() - start_time
			remaining = int(timeout - elapsed)

			# Update status display every second
			if elapsed - last_print_time >= 1.0:
				print(f"\rWaiting for device reconnection... {remaining}s remaining  ", end="", flush=True)
				last_print_time = elapsed

			# Check if device appeared
			target_port = self.__oldPort

			if target_port:
				# Try to open the port to verify it's ready
				try:
					test_port = serial.Serial(port=target_port, baudrate=self.__args.baudRate, timeout=1)
					test_port.close()

					print(f"\n\nDevice detected: {target_port}")
					self.__serialPortPath = target_port
					return True
					
				except Exception:
					# Port exists but not ready yet, wait a bit
					time.sleep(DEVICE_READY_WAIT)
					continue

			# Short sleep before next check
			time.sleep(SERIAL_RECONNECT_CHECK_INTERVAL)

		print(f"\n\nTimeout: Device did not reconnect within {timeout} seconds.")
		return False

	def _reconnect_serial(self) -> bool:
		"""Attempt to reconnect to the serial port."""
		try:
			if self.__serialPort and self.__serialPort.is_open:
				self.__serialPort.close()
		except:
			pass
		
		# Wait for device to reappear
		if not self._wait_for_serial_reconnect():
			return False

		try:
			# Reopen the port for normal communication
			self.__serialPort = serial.Serial(
				port=self.__serialPortPath,
				baudrate=self.__args.baudRate,
				timeout=15
			)

			# Clear any buffered data
			time.sleep(BUFFER_CLEAR_WAIT)
			if self.__serialPort.in_waiting > 0:
				self.__serialPort.read(self.__serialPort.in_waiting)

			return True

		except Exception as e:
			print(f"Failed to reconnect to serial port: {e}")
			return False

	def __getEtherAddress(self):
		configFile = os.path.join(self.__scriptDir, ".." , "config", 'boards_flash_config.toml')
		with open(configFile, "rb") as f:
			eth_info = tomllib.load(f)

		self.__etherAddress = eth_info[self.__args.boardName]["ethernet"]

		if self.__etherAddress is None:
			print(f"Board name {self.__args.boardName} is not supported.")
			exit()

	def __listDevice(self):
		fb = self.__fastboot
		cmd = [fb, "devices"]
		try:
			res = subprocess.run(
				cmd,
				capture_output=True,
				text=True,
				check=False,
				timeout=10
			)
		except subprocess.TimeoutExpired:
			die(msg="fastboot timed out while listing devices")

		if res.returncode != 0:
			die(msg=f"fastboot failed (rc={res.returncode}): {res.stderr.strip()}")

		out = (res.stdout or "").strip()
		devices = []
		for line in out.splitlines():
			parts = line.split()
			if len(parts) >= 2 and parts[1].startswith("fastboot"):
				devices.append(parts[0])

		if devices:
			print("Fastboot device(s): " + ", ".join(devices))
		else:
			print("No fastboot devices detected.")
		return devices

	def __verify_mmc_device(self):
		"""Verify that the MMC device is accessible on the board"""
		try:
			self.__writeSerialCmd('mmc dev 0')

			# Read response with timeout
			timeout = BUFFER_CHECK_TIMEOUT
			start_time = time.time()
			accumulated_data = ""

			while time.time() - start_time < timeout:
				if self.__serialPort.in_waiting > 0:
					new_data = self.__serialPort.read(self.__serialPort.in_waiting).decode(errors='ignore')
					accumulated_data += new_data
					print(new_data, end='', flush=True)

					# Check for success or error conditions
					if 'OK' in accumulated_data or '=>' in accumulated_data:
						break

				time.sleep(0.1)

			# Check for error conditions
			if 'error' in accumulated_data.lower() or 'did not respond' in accumulated_data.lower():
				return False

			if 'OK' not in accumulated_data and '=>' not in accumulated_data:
				print("\nWarning: Unexpected response from mmc dev command.")
				return False

			print("\nMMC device verified successfully.\n")
			return True

		except Exception as e:
			print(f"Error verifying MMC device: {e}")
			return False

	# Function to write bootloader
	def writeRootfs(self):
		start_time = time.time()

		# Check file exists
		if not os.path.exists(self.__args.rootfsImage):
			print(f"The file {self.__args.rootfsImage} does not exist.")
			exit()

		# Wait for device to be ready to receive image.
		print("\nPlease power off the board, set the DIP switches to the normal boot mode, and then power the board back on." \
		"\nNote: Setting an incorrect boot mode may lead to unexpected behavior.")
		print(f"\n{'='*SEPARATOR_WIDTH}")
		print("** IMPORTANT: Do not change the Serial port and the Ethernet, or the USB compared to the initial setup. **")
		print(f"{'='*SEPARATOR_WIDTH}\n")

		# Try to read from serial with reconnection support
		if not self.__serialReadWithReconnect('Hit any key to stop autoboot:', allow_uboot_prompt=True):
			die(msg='Failed to communicate with board after reconnection attempts.')

		# Send enter to get fresh prompt (in case we're already at prompt)
		self.__writeSerialCmd('')
		time.sleep(BUFFER_CHECK_WAIT)

		# Clear any buffered data and verify we have prompt
		if self.__serialPort.in_waiting > 0:
			data = self.__serialPort.read(self.__serialPort.in_waiting).decode(errors='ignore')
			print(data, end='', flush=True)

		# Send another enter to get prompt
		self.__writeSerialCmd('')
		self.__serialRead('=>')

		# Verify MMC device is accessible before proceeding with fastboot
		if not self.__verify_mmc_device():
			die(msg='MMC 0 device not accessible.\n\n' \
				'Check:\n' \
				'  - SD card is inserted (if mmc0 is SD card)\n' \
				'  - eMMC is accessible (if mmc0 is eMMC)\n' \
				'  - DIP/SOM switches set correctly for boot device selection\n' \
				'    (e.g., RZ/G2L-EVK, RZ/V2L-EVK)\n' \
				'  - Device is not corrupted\n\n' \
				'Refer to the README file for your board\'s MMC 0 configuration.')

		# UDP Fastboot
		if (self.__args.fastbootType == "udp"):
			self.__handle_udp_fastboot()
		# OTG Fastboot
		elif (self.__args.fastbootType == "otg"):
			self.__handle_otg_fastboot()

		print("Closed serial port.")
		self.__serialPort.close()

		end_time = time.time()
		elapsed_time = end_time - start_time
		print(f"Elapsed time: {elapsed_time:.6f} seconds")

	def __handle_udp_fastboot(self):
		self.__getEtherAddress()

		print('fastboot udp mode')
		self.__writeSerialCmd('setenv ipaddr ' + self.__args.ipAddress)
		self.__writeSerialCmd(f'setenv ethact ethernet@{self.__etherAddress[self.__args.etherPort]}')
		self.__writeSerialCmd('fastboot udp')
		self.__serialRead('Listening for fastboot command on')

		# Give time for UDP fastboot to fully initialize
		print('Waiting for fastboot UDP service to initialize...')
		# time.sleep(5)

		print('Starting fastboot command to write rootfs image...')

		if platform.system() == "Windows":
			fastboot_command = f"{self.__fastboot} -s udp:{self.__args.ipAddress} -v"
		elif platform.system() == "Linux":
			# fasboot in linux does not support the -v flag for verbose output
			fastboot_command = f"{self.__fastboot} -s udp:{self.__args.ipAddress}"

		# Run fastboot commands only once (no retry)
		self.__runSubprocessCommand(f"{fastboot_command} getvar version-bootloader")
		self.__runSubprocessCommand(f"{fastboot_command} getvar version")
		# `rawimg` is the standard target for every board, including
		# Sparrow-Hawk. The matching U-Boot rawimg backend resolves the target
		# from the runtime `mmcdev` environment variable and falls back to
		# CONFIG_FASTBOOT_FLASH_MMC_DEV only when `mmcdev` is unset.
		self.__runSubprocessCommand(f"{fastboot_command} flash rawimg {self.__args.rootfsImage}")

	def __handle_otg_fastboot(self):
		print('fastboot usb otg mode')
		self.__writeSerialCmd(f"setenv serial# {self.__fastbootDevice}")
		self.__writeSerialCmd('saveenv')
		self.__serialRead('OK')
		self.__writeSerialCmd('fastboot usb 27')
		# Wait for USB OTG device to enumerate on the host
		time.sleep(3)

		devs = self.__listDevice()
		if f"{self.__fastbootDevice}" not in devs:
			die(msg=(
				f"Fastboot device '{self.__fastbootDevice}' not found.\n"
				"Ensure the board is connected via the USB OTG port and that all prerequisites (see README) are met"
			))

		self.__runSubprocessCommand(f"{self.__fastboot} -s {self.__fastbootDevice} flash mmc0 {self.__args.rootfsImage}")

	def __runSubprocessCommand(self, command):
		try:
			subprocess.run(command, shell=True, check=True)
		except CalledProcessError as e:
			die(msg=f"Command '{command}' failed with error: {e.stderr.decode().strip()}")

	def __writeSerialCmd(self, cmd):
		self.__serialPort.write(f'{cmd}\r'.encode())

	def __serialReadWithReconnect(self, cond='\n', max_retries=MAX_RECONNECT_RETRIES, allow_uboot_prompt=False) -> bool:
		"""Read from serial with automatic reconnection on failure.
		Args:
			cond: The condition string to wait for
			max_retries: Maximum number of retry attempts
			allow_uboot_prompt: If True, also accept U-Boot prompt (=>) as success condition
		"""
		for attempt in range(max_retries):
			try:
				# Clear any existing buffer data
				discarded = None
				if self.__serialPort.in_waiting > 0:
					discarded = self.__serialPort.read(self.__serialPort.in_waiting)

				# If we discarded data, wait for board to power cycle and come back
				if discarded:
					print("Waiting for board to power cycle...", flush=True)
					boot_timeout = WAIT_POWER_TIMEOUT
					boot_start = time.time()
					while time.time() - boot_start < boot_timeout:
						if self.__serialPort.in_waiting > 0:
							break
						time.sleep(0.2)
					else:
						print("Timeout waiting for power on", flush=True)
						return False

				# Wait for the expected prompt
				prompt_timeout = WAIT_POWER_TIMEOUT
				prompt_start = time.time()
				accumulated_data = ""

				while time.time() - prompt_start < prompt_timeout:
					if self.__serialPort.in_waiting > 0:
						new_data = self.__serialPort.read(self.__serialPort.in_waiting).decode(errors='ignore')
						print(new_data, end='', flush=True)
						accumulated_data += new_data
						
						if cond in accumulated_data or (allow_uboot_prompt and '=>' in accumulated_data):
							return True

					time.sleep(0.1)

				# Timeout reached without seeing the expected prompt
				print(f"Timeout waiting for prompt '{cond}'", flush=True)
				return False

			except serial.SerialException as e:
				if attempt < max_retries - 1:
					if self._reconnect_serial():
						if allow_uboot_prompt:
							return True
						continue

				print(f"Serial exception: {e}", flush=True)
				return False

			except Exception as e:
				if attempt < max_retries - 1:
					if self._reconnect_serial():
						if allow_uboot_prompt:
							return True
						continue

				print(f"Unexpected error: {type(e).__name__}: {e}")
				return False

		print(f"Failed to communicate with board after {max_retries} attempts.")
		return False

	# Function to wait and print contents of serial buffer
	def __serialRead(self, cond='\n'):
		buf = self.__serialPort.read_until(cond.encode())

		if not buf:
			print("Returned value is not the expectation. Expecting: {}.\n Exiting!".format(cond))
			exit()

		print(f'{buf.decode(errors="ignore")}')

# Util function to die with error
def die(msg='', code=1):
	print(f'Error: {msg}')
	exit(code)

def main():
	sdFlashUtil = SdFlashUtil()

	sdFlashUtil.writeRootfs()

if __name__ == '__main__':
	main()
