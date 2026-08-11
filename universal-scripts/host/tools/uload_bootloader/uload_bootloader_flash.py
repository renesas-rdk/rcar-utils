#!/usr/bin/python3

# Imports
import serial
import argparse
import time
import os
import glob
import re
from serial.tools.list_ports import comports
import sys
if sys.version_info >= (3, 11):  # pragma: Python version >=3.11
	import tomllib
else:  # pragma: Python version <3.11
	import tomli as tomllib

DEFAULT_MEDIA_DIR = "uload-bootloader"   # on FAT32 partition
SEPARATOR_WIDTH = 85  # Width for separator lines in console output
WAIT_POWER_TIMEOUT = 120
SERIAL_RECONNECT_TIMEOUT = 30
SERIAL_RECONNECT_CHECK_INTERVAL = 0.1
SERIAL_READ_TIMEOUT = 10
SERIAL_READ_BUFFER_SIZE = 4096
DEVICE_READY_WAIT = 0.2
BUFFER_CLEAR_WAIT = 0.5
BUFFER_CHECK_WAIT = 0.3
MAX_RECONNECT_RETRIES = 3
SERIAL_BY_ID_DIR = "/dev/serial/by-id"

class UloadFlashUtil:
	def __init__(self, args=None):
		self.__scriptDir = os.path.dirname(os.path.abspath(__file__))
		self.__oldPort = None

		self.__setupArgumentParser(args)
		self.__setupSerialPort()

	def __is_v4h(self):
		return self.__args.boardName == "sparrow-hawk"

	def __setupArgumentParser(self, args):
		self.__parser = argparse.ArgumentParser(
			description='Util to flash bootloader from U-Boot console on RZ and R-Car boards.\n'
						'NOTE: Images must be on the SD card FAT32 partition 1.\n',
			epilog='Example:\n  ./uload_bootloader_flash.py --board_name rzg2l-sbc'
		)
		# Board name
		self.__parser.add_argument('--board_name',
									default='rzg2l-sbc',
									dest='boardName',
									type=str,
									help='Board name to flash bootloader (default: rzg2l-sbc).')

		# Serial
		self.__parser.add_argument('--serial_port',
									default=None,
									dest='serialPort',
									help='Serial port to talk to the board (default: newest connected port).')
		self.__parser.add_argument('--serial_port_by_id',
									default=None,
									dest='serialPortById',
									action='store',
									help='Serial port by-id path for reliable reconnection (e.g., /dev/serial/by-id/...).')
		self.__parser.add_argument('--serial_port_baud',
									default=115200,
									dest='baudRate',
									type=int,
									help='Baud rate (default: 115200).')

		# media paths on the FAT32 partition
		# If only a filename is provided, it will search DEFAULT_MEDIA_DIR/ (uload-bootloader)
		self.__parser.add_argument('--bl2_path',
									dest='bl2Path',
									default=None,
									type=str,
									help='Path/filename of BL2 image on SD (e.g., "uload-bootloader/bl2_bp_rzg2l-sbc.bin" '
									'or just "bl2_bp_rzg2l-sbc.bin").')
		self.__parser.add_argument('--spl_path',
									dest='splPath',
									default=None,
									type=str,
									help='V4H only: path/filename of the SA0+SPL image on SD.')
		self.__parser.add_argument('--fip_path',
									dest='fipPath',
									default=None,
									type=str,
									help='Path/filename of FIP image on SD.')
		self.__parser.add_argument('--uboot_fit_path',
									dest='ubootFitPath',
									default=None,
									type=str,
									help='V4H only: path/filename of the board-specific U-Boot FIT on SD.')
		self.__parser.add_argument('--image_bid',
									dest='bidPath',
									default=None,
									type=str,
									help='Path/filename of board-ID/platform-settings binary on SD.')
		self.__parser.add_argument('--pcie_fw_path',
									dest='pcieFwPath',
									default=None,
									type=str,
									help='V4H only: path/filename of PCIe firmware on SD.')

		if args:
			self.__args = self.__parser.parse_args(args)
		else:
			self.__args = self.__parser.parse_args()

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

	def __getUloadFlashInfo(self):
		configFile = os.path.join(self.__scriptDir, "..", "config", 'boards_flash_config.toml')
		with open(configFile, "rb") as f:
			flash_info = tomllib.load(f)

		try:
			self.__uloadFlashInfo = flash_info[self.__args.boardName]
		except KeyError:
			die(msg=f'Board name "{self.__args.boardName}" is not supported.')
		if self.__is_v4h() and "uload" not in self.__uloadFlashInfo:
			die(msg='Sparrow-Hawk ULoad xSPI layout is not configured.')

	@staticmethod
	def __resolve_media_path(name_or_path: str) -> str:
		"""Return a path usable by U-Boot fatload.
		If only a filename is given (no '/'), prepend DEFAULT_MEDIA_DIR/."""
		if name_or_path is None:
			return None
		if '/' in name_or_path or '\\' in name_or_path:
			return name_or_path.replace('\\', '/')
		return f"{DEFAULT_MEDIA_DIR}/{name_or_path}"

	def __v4h_fatload(self, load_address, path, label, size_var=None):
		"""Load one V4H artifact from the SD card's FAT32 boot partition."""
		print(f'Loading {label} from mmc ${{mmcdev}}:${{mmcpart}}: {path}')
		self.__writeSerialCmd(f'fatload mmc ${{mmcdev}}:${{mmcpart}} {load_address} {path}')
		response = self.__serialRead('=>')
		match = re.search(r'(\d+) bytes read', response)
		if not match:
			die(msg=f'Unable to load V4H {label} from mmc ${{mmcdev}}:${{mmcpart}}: {path}')
		if size_var:
			self.__writeSerialCmd(f'setenv {size_var} ${{filesize}}')
			self.__serialRead('=>')
		return int(match.group(1))

	@staticmethod
	def __v4h_require(response, expected, action):
		if expected not in response:
			die(msg=f'V4H {action} failed; expected "{expected}" in U-Boot response.')

	def __v4h_crc32(self, address, size, label):
		self.__writeSerialCmd(f'crc32 {address} 0x{size:x}')
		# Do not wait for plain '=>': it occurs inside U-Boot's CRC output
		# ('==> <crc>').  The line break identifies the actual shell prompt.
		response = self.__serialRead('\n=>')
		match = re.search(r'==>\s*([0-9a-fA-F]{8})', response)
		if not match:
			die(msg=f'Unable to calculate V4H {label} CRC32.')
		return match.group(1).lower()

	def __wait_for_v4h_uboot_prompt(self):
		"""Accept an already-running U-Boot for recovery, otherwise wait for reboot."""
		self.__writeSerialCmd('')
		prompt_deadline = time.time() + 2
		while time.time() < prompt_deadline:
			if self.__serialPort.in_waiting > 0:
				response = self.__serialPort.read(self.__serialPort.in_waiting).decode(errors='ignore')
				print(response, end='', flush=True)
				if '=>' in response:
					return True
			time.sleep(0.1)
		return self.__serialReadWithReconnect(
			'Hit any key to stop autoboot:', allow_uboot_prompt=True)

	def __write_v4h_xspi_file(self, load_address, verify_address, path, offset,
							label, max_size):
		payload_size = self.__v4h_fatload(load_address, path, label)
		write_size = (payload_size + 3) & ~3
		if write_size > max_size:
			die(msg=f'V4H {label} aligned size 0x{write_size:x} exceeds its xSPI region.')
		source_crc = self.__v4h_crc32(load_address, payload_size, label)
		if write_size != payload_size:
			print(f'Padding {label} write from 0x{payload_size:x} to 0x{write_size:x} bytes.')
			padding_address = int(load_address, 0) + payload_size
			self.__writeSerialCmd(f'mw.b 0x{padding_address:x} 0xff {write_size - payload_size}')
			self.__serialRead('=>')
		print(f'Writing {label} to xSPI offset 0x{offset}...')
		# R-Car V4H U-Boot sf write silently drops a non-4-byte tail.  The
		# padded byte(s) occupy only the validated gap following this payload.
		self.__writeSerialCmd(f'sf write {load_address} {offset} 0x{write_size:x}')
		response = self.__serialRead('=>')
		self.__v4h_require(response, 'Written: OK', f'{label} write')

		self.__writeSerialCmd(f'sf read {verify_address} {offset} 0x{payload_size:x}')
		response = self.__serialRead('=>')
		self.__v4h_require(response, 'Read: OK', f'{label} readback')
		readback_crc = self.__v4h_crc32(verify_address, payload_size, f'{label} readback')
		if source_crc != readback_crc:
			die(msg=(f'V4H {label} CRC mismatch after write: '
					 f'source={source_crc}, SPI={readback_crc}.'))
		print(f'Verified {label} CRC32: {source_crc}')

	def __write_v4h_uload_bootloader(self):
		"""Program the V4H SPL/FIT/BID/PCIe layout from U-Boot's FAT partition."""
		layout = self.__uloadFlashInfo['uload']
		load_address = self.__uloadFlashInfo['load_address']
		verify_address = layout['verify_address']

		spl_path = self.__resolve_media_path(
			self.__args.splPath or f'spl_bp_{self.__args.boardName}.bin')
		uboot_fit_path = self.__resolve_media_path(
			self.__args.ubootFitPath or self.__args.fipPath
			or f'u-boot_{self.__args.boardName}.itb')
		bid_path = self.__resolve_media_path(
			self.__args.bidPath or f'{self.__args.boardName}-platform-settings.bin')
		pcie_path = self.__resolve_media_path(
			self.__args.pcieFwPath or 'rcar_gen4_pcie.bin')

		artifacts = [
			('SPL (SA0+SPL)', spl_path, 'uload_spl_size', 'SPL'),
			('U-Boot FIT', uboot_fit_path, 'uload_uboot_fit_size', 'UBOOT_FIT'),
			('BID', bid_path, 'uload_bid_size', 'BID'),
			('PCIe firmware', pcie_path, 'uload_pcie_size', 'PCIE'),
		]

		print("V4H image sources on the SD card's FAT32 partition 1:")
		for label, path, _, _ in artifacts:
			print(f'  {label}: {path}')

		print('\nPlease power off the board, select normal boot mode, then power it on.')
		print('An existing U-Boot prompt can also be used for recovery.')
		if not self.__wait_for_v4h_uboot_prompt():
			die(msg='Failed to communicate with V4H U-Boot after reconnection attempts.')
		self.__writeSerialCmd('')
		self.__serialRead('=>')
		self.__writeSerialCmd('sf probe')
		response = self.__serialRead('=>')
		self.__v4h_require(response, 'Detected', 'SPI probe')

		# Load every file before erasing SPI.  The size test uses a 0x prefix
		# because U-Boot stores ${filesize} as an unprefixed hexadecimal string.
		print('\nPre-checking V4H artifacts before erase...')
		for label, path, size_var, offset_key in artifacts:
			payload_size = self.__v4h_fatload(load_address, path, label, size_var)
			max_size = int(layout['bid_size'] if offset_key == 'BID'
						   else layout[f'{offset_key.lower()}_max_size'], 16)
			if payload_size <= 0 or ((payload_size + 3) & ~3) > max_size:
				die(msg=f'V4H {label} does not fit its xSPI region after 4-byte alignment.')

		check_cmd = (
			'if test 0x${uload_spl_size} -gt 0 && '
			f'test 0x${{uload_spl_size}} -le 0x{layout["spl_max_size"]} && '
			'test 0x${uload_uboot_fit_size} -gt 0 && '
			f'test 0x${{uload_uboot_fit_size}} -le 0x{layout["uboot_fit_max_size"]} && '
			f'test 0x${{uload_bid_size}} -eq 0x{layout["bid_size"]} && '
			'test 0x${uload_pcie_size} -gt 0 && '
			f'test 0x${{uload_pcie_size}} -le 0x{layout["pcie_max_size"]}; '
			'then echo V4H_ULOAD_PRECHECK_OK; else echo V4H_ULOAD_PRECHECK_FAIL; fi'
		)
		self.__writeSerialCmd(check_cmd)
		response = self.__serialRead('=>')
		if 'V4H_ULOAD_PRECHECK_OK' not in response:
			die(msg='V4H ULoad size pre-check failed; SPI flash was not erased.')

		print('Erasing V4H xSPI region...')
		self.__writeSerialCmd(f'sf erase 0 {layout["erase_size"]}')
		response = self.__serialRead('=>')
		self.__v4h_require(response, 'Erased: OK', 'xSPI erase')

		for label, path, _, offset_key in artifacts:
			max_size = int(layout['bid_size'] if offset_key == 'BID'
						   else layout[f'{offset_key.lower()}_max_size'], 16)
			self.__write_v4h_xspi_file(
				load_address, verify_address, path, layout[offset_key], label, max_size)

		print('\nV4H ULoad bootloader flashing completed successfully.')
		self.__serialPort.close()

	def writeUloadBootloader(self):
		start_time = time.time()

		self.__getUloadFlashInfo()
		if self.__is_v4h():
			self.__write_v4h_uload_bootloader()
			print(f"Total elapsed time: {time.time() - start_time:.3f} s")
			return
		xspiFlashAddress = self.__uloadFlashInfo["flash_address"]
		loadAddress = self.__uloadFlashInfo["load_address"]

		# Derive defaults from boardName if user didn’t pass custom paths
		default_bl2_name = f"bl2_bp_{self.__args.boardName}.bin"
		default_fip_name = f"fip_{self.__args.boardName}.bin"
		default_bid_name = f"{self.__args.boardName}-platform-settings.bin"

		bl2_path = self.__resolve_media_path(self.__args.bl2Path or default_bl2_name)
		fip_path = self.__resolve_media_path(self.__args.fipPath or default_fip_name)
		bid_path = self.__resolve_media_path(self.__args.bidPath or default_bid_name)

		print("Image sources on the SD card's FAT32 partition 1:")
		print(f"  BL2 : {bl2_path}")
		print(f"  FIP : {fip_path}")
		print(f"  BID : {bid_path}")

		# Wait for device to be ready to receive image.
		print("\nPlease power off the board, set the DIP switches to the normal boot mode, and then power the board back on." \
		"\nNote: Setting an incorrect boot mode may lead to unexpected behavior.")
		print(f"\n{'='*SEPARATOR_WIDTH}")
		print("** IMPORTANT: Do not change the Serial port compared to the initial setup. **")
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

		# Probe xSPI flash
		self.__writeSerialCmd('sf probe')
		self.__serialRead('MiB')

		self.__writeSerialCmd('true')
		self.__serialRead('=>')

		# Pre-check: Verify all files exist on SD card before erasing SPI flash
		print('\n' + '='*SEPARATOR_WIDTH)
		print('** Pre-check: Verifying all required files on SD card **')
		print('='*SEPARATOR_WIDTH)

		files_to_check = [
			('BL2', bl2_path),
			('FIP', fip_path),
			('BID', bid_path)
		]

		# Use fatls to list the directory once
		print(f'\nListing files in {DEFAULT_MEDIA_DIR}/')
		self.__writeSerialCmd(f'fatls mmc ${{mmcdev}}:${{mmcpart}} {DEFAULT_MEDIA_DIR}/')

		# Read the directory listing - wait for file(s) indicator then prompt
		buf = self.__serialPort.read_until(b'file(s)', size=8192)
		buf += self.__serialPort.read_until(b'=>', size=1024)
		dir_listing = buf.decode(errors='ignore')
		print(dir_listing, end='', flush=True)

		# Check if each file exists in the directory listing
		all_files_ok = True
		for file_type, file_path in files_to_check:
			# Extract just the filename from the path (e.g., "uload-bootloader/bl2_bp_rzg2l-sbc.bin" -> "bl2_bp_rzg2l-sbc.bin")
			filename = file_path.split('/')[-1]

			if filename in dir_listing:
				print(f'  [OK] {file_type}: {filename}')
			else:
				print(f'  [MISSING] {file_type}: {filename}')
				all_files_ok = False

		if not all_files_ok:
			print('\n' + '='*SEPARATOR_WIDTH)
			print('** Pre-check FAILED: Missing or inaccessible files on SD card **')
			print('='*SEPARATOR_WIDTH)
			print(f'\nPlease verify that all files exist in {DEFAULT_MEDIA_DIR}/ on SD card partition 1 (FAT32).')
			print('SPI flash was NOT erased. Board is still in bootable state.')
			print('\nFor troubleshooting and detailed instructions, refer to:')
			print('  universal-scripts/host/tools/uload_bootloader/README.md -> Troubleshooting section')
			self.__serialPort.close()
			die(msg='Pre-check failed. Aborting flash operation.')

		print('\n' + '='*SEPARATOR_WIDTH)
		print('** Pre-check PASSED: All files verified on SD card **')
		print('='*SEPARATOR_WIDTH)
		print('\nProceeding with SPI flash erase and write operations...\n')

		# Erase a safe region (adjust size as needed)
		print('Erasing xSPI: please wait...')
		start_time_erase = time.time()
		self.__writeSerialCmd('sf erase 0 100000')
		self.__serialRead('OK')
		print(f"Erase time: {time.time() - start_time_erase:.3f} s")

		self.__writeSerialCmd('true')
		self.__serialRead('=>')

		# Loading BL2
		print('\nWriting BL2 to SPI flash...')
		self.__writeSerialCmd(f'fatload mmc ${{mmcdev}}:${{mmcpart}} {loadAddress} {bl2_path}')
		self.__serialRead('MiB/s)')

		self.__writeSerialCmd('true')
		self.__serialRead('=>')

		self.__writeSerialCmd(f'sf write {loadAddress} {xspiFlashAddress[0]} $filesize')
		self.__serialRead('OK')

		self.__writeSerialCmd('true')
		self.__serialRead('=>')

		# Loading FIP
		print('\nWriting FIP to SPI flash...')
		self.__writeSerialCmd(f'fatload mmc ${{mmcdev}}:${{mmcpart}} {loadAddress} {fip_path}')
		self.__serialRead('MiB/s)')

		self.__writeSerialCmd('true')
		self.__serialRead('=>')

		self.__writeSerialCmd(f'sf write {loadAddress} {xspiFlashAddress[1]} $filesize')
		self.__serialRead('OK')

		self.__writeSerialCmd('true')
		self.__serialRead('=>')

		# Loading Board Identification
		print('\nWriting Board ID to SPI flash...')
		self.__writeSerialCmd(f'fatload mmc ${{mmcdev}}:${{mmcpart}} {loadAddress} {bid_path}')
		self.__serialRead('MiB/s)')

		self.__writeSerialCmd('true')
		self.__serialRead('=>')

		self.__writeSerialCmd(f'sf write {loadAddress} {xspiFlashAddress[2]} $filesize')
		self.__serialRead('OK')

		self.__writeSerialCmd('true')
		self.__serialRead('=>')

		print('\n' + '='*SEPARATOR_WIDTH)
		print('** Bootloader flashing completed successfully! **')
		print('='*SEPARATOR_WIDTH)
		print("Closed serial port.")
		self.__serialPort.close()

		print(f"Total elapsed time: {time.time() - start_time:.3f} s")

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

	def __writeSerialCmd(self, cmd):
		self.__serialPort.write(f'{cmd}\r'.encode())

	# Function to wait and print contents of serial buffer
	def __serialRead(self, cond='\n'):
		buf = self.__serialPort.read_until(cond.encode())
		if not buf:
			print("Returned value is not the expectation. Exiting.")
			exit()
		decoded = buf.decode(errors="ignore")
		print(decoded)
		return decoded

# Util function to die with error
def die(msg='', code=1):
	print(f'Error: {msg}')
	exit(code)

def main():
	tool = UloadFlashUtil()
	tool.writeUloadBootloader()

if __name__ == '__main__':
	main()
