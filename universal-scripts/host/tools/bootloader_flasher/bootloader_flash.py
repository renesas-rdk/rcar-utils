#!/usr/bin/env python3

# Imports
import serial
import argparse
import platform
import shutil
import subprocess
import time
import os
import glob
from serial.tools.list_ports import comports
import sys
if sys.version_info >= (3, 11):  # pragma: Python version >=3.11
    import tomllib
else:  # pragma: Python version <3.11
    import tomli as tomllib

# Constants
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

class BootloaderFlashUtil:
	def __init__(self, args=[]):
		self.__scriptDir = os.path.dirname(os.path.abspath(__file__))
		self.__rootDir = os.path.abspath(os.path.join(self.__scriptDir, '..', '..', '..'))
		self.__imagesDir = os.path.abspath(os.path.join(self.__rootDir, 'target', 'images'))
		self.__sdCardDevice = None

		if platform.system() == "Windows":
			self.__dd = os.path.abspath(os.path.join(self.__scriptDir, 'tools', 'dd.exe'))
		elif platform.system() == "Linux":
			self.__dd = "dd"
		self.__oldPort = None
		self.__initialConnection = True

		self.__setupArgumentParser(args)
		self.__getFlashAddress()

	def __is_v4h(self):
		return self.__args.boardName == "sparrow-hawk"

	def __ipl_label(self):
		return "SPL" if self.__is_v4h() else "BL2"

	def __ipl_config_key(self, flash_config):
		key = "SPL" if self.__is_v4h() else "BL2"
		if key not in flash_config:
			die(msg=f'{key} flash address is not configured for board {self.__args.boardName}.')
		return key

	def __ipl_image(self):
		if self.__is_v4h():
			if not self.__args.splImage:
				die(msg='--image_spl must be provided for V4H boards.')
			return self.__args.splImage
		return self.__args.bl2Image

	def __ipl_esd_image(self):
		if self.__is_v4h():
			if not self.__args.splEsdImage:
				die(msg='--image_spl_esd must be provided for V4H eSD flashing.')
			return self.__args.splEsdImage
		return self.__args.bl2EsdImage

	# Setup CLI parser
	def __setupArgumentParser(self, args=[]):
		# Create parser
		self.__parser = argparse.ArgumentParser(description='Util to flash bootloader on RZ Board.\n', epilog='Example:\n\t./bootloader_flash.py')

		# Add arguments
		# Board name
		self.__parser.add_argument('--board_name',
									default='rzg2l-sbc',
									dest='boardName',
									action='store',
									type=str,
									help='Board name to flash bootloader (defaults to: rzg2l-sbc).')
		self.__parser.add_argument('--flash_method',
									default='xspi',
									dest='flashMethod',
									action='store',
									type=str,
									choices=['emmc', 'xspi', 'esd'],
									help='Flash method to use (defaults to: xspi).')

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
		self.__parser.add_argument('--image_writer',
									default=f'{self.__imagesDir}/Flash_Writer_SCIF_rzg2l-sbc.mot',
									dest='flashWriterImage',
									action='store',
									type=str,
									help="Path to Flash Writer image (defaults to: <path/to/your/package>/target/images/Flash_Writer_SCIF_rzg2l-sbc.mot).")
		self.__parser.add_argument('--image_bl2',
									default=f'{self.__imagesDir}/bl2_bp_rzg2l-sbc.srec',
									dest='bl2Image',
									action='store',
									type=str,
									help='Path to bl2 image (defaults to: <path/to/your/package>/target/images/bl2_bp_rzg2l-sbc.srec).')
		self.__parser.add_argument('--image_spl',
									default=None,
									dest='splImage',
									action='store',
									type=str,
									help='Path to SPL image for V4H boards (SA0 header + SPL binary).')
		self.__parser.add_argument('--image_bl2_esd',
									default=f'{self.__imagesDir}/bl2_bp_esd_rzg2l-sbc.bin',
									dest='bl2EsdImage',
									action='store',
									type=str,
									help='[Only used in eSD Flash] (defaults to: <path/to/your/package>/target/images/bl2_bp_esd_rzg2l-sbc.bin).')
		self.__parser.add_argument('--image_spl_esd',
									default=None,
									dest='splEsdImage',
									action='store',
									type=str,
									help='[Only used in V4H eSD Flash] Path to SPL eSD image.')
		self.__parser.add_argument('--image_fip',
									default=f'{self.__imagesDir}/fip_rzg2l-sbc.srec',
									dest='fipImage',
									action='store',
									type=str,
									help='Path to FIP image (defaults to: <path/to/your/package>/target/images/fip_rzg2l-sbc.srec).')
		self.__parser.add_argument('--image_bid',
									default=f'{self.__imagesDir}/rzg2l-sbc-platform-settings.bin',
									dest='bidImage',
									action='store',
									type=str,
									help='Path to board identification image (defaults to: <path/to/your/package>/target/images/rzg2l-sbc-platform-settings.bin).')
		self.__parser.add_argument('--image_pcie_fw',
									default=None,
									dest='pcieFwImage',
									action='store',
									type=str,
									help='Path to PCIe PHY firmware (rcar_gen4_pcie.bin) for V4H boards.')
		self.__parser.add_argument('--esd_device',
									dest='esdDevice',
									action='store',
									type=str,
									help='[Only used in eSD Flash] Raw device path of the SD card to program (e.g., /dev/sda or E: SDCARD).')

		if args:
			self.__args = self.__parser.parse_args(args)
		else:
			self.__args = self.__parser.parse_args()

	@property
	def flashMethod(self):
		return self.__args.flashMethod

	# Setup Serial Port
	def setupSerialPort(self):
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

	def __getFlashAddress(self):
		configFile = os.path.join(self.__scriptDir, ".." , "config", 'boards_flash_config.toml')
		with open(configFile, "rb") as f:
			flash_info = tomllib.load(f)

		self.__flashAddress = flash_info[self.__args.boardName]

		if self.__flashAddress is None:
			print(f"Board name {self.__args.boardName} is not supported.")
			exit()

	# Setup Serial Port SUP
	def __setupSerialPort_SUP(self):
		try:
			self.__serialPort.baudrate = 921600
		except:
			die(msg='Unable to open serial port 921600 bps.')

	def __prompt_timeout_for_file(self, file_path, min_timeout=30):
		"""Scale the wait timeout to file size so large SREC/binary uploads
		(e.g. sparrow-hawk's ~5MB FIP) aren't cut off before the Flash Writer
		finishes erasing/programming and prints the next prompt."""
		try:
			size = os.path.getsize(file_path)
		except OSError:
			return min_timeout
		bytes_per_sec = self.__args.baudRate / 10  # 8N1 framing
		estimated = size / bytes_per_sec
		return max(min_timeout, int(estimated * 2) + 15)

	def __wait_for_prompt(self, timeout=30):
		end_time = time.time() + timeout
		buffer = b""
		sent_y = False

		while time.time() < end_time:
			if self.__serialPort.in_waiting:
				buffer += self.__serialPort.read(self.__serialPort.in_waiting)
				decoded = buffer.decode(errors='ignore')

				if not sent_y and "Clear OK" in decoded:
					self.__writeSerialCmd('y')
					sent_y = True  # prevent sending again

				if ">" in decoded:
					break

			time.sleep(0.1)

		print(f'{buffer.decode(errors="ignore")}')

	# Function to write bootloader
	def writeBootloader(self):
		start_time = time.time()

		# Check file exists
		if not os.path.exists(self.__args.flashWriterImage):
			print(f"The file {self.__args.flashWriterImage} does not exist.")
			exit()
		ipl_image = self.__ipl_image()
		if not os.path.exists(ipl_image):
			print(f"The file {ipl_image} does not exist.")
			exit()
		if not os.path.exists(self.__args.fipImage):
			print(f"The file {self.__args.fipImage} does not exist.")
			exit()
		if self.__args.pcieFwImage and not os.path.exists(self.__args.pcieFwImage):
			print(f"The file {self.__args.pcieFwImage} does not exist.")
			exit()
		if not os.path.exists(self.__args.bidImage):
			print(f"The file {self.__args.bidImage} does not exist.")
			exit()

		# Wait for device to be ready to receive image.
		print("\nPlease power off the board, set the DIP switches to SCIF download mode, and then power the board back on." \
		"\nNote: Setting an incorrect boot mode may lead to unexpected behavior.")
		print(f"\n{'='*SEPARATOR_WIDTH}")
		print("** IMPORTANT: Do not change the Serial port compared to the initial setup. **")
		print(f"{'='*SEPARATOR_WIDTH}\n")

		# TODO: Each board has the different responses.
		# We need to list out all the supported responses corresponding to the supported boards.
		# Try to read from serial with reconnection support
		if (self.__args.boardName == "sparrow-hawk"):
			ok = self.__serialReadWithReconnect('Load Program to RT-SRAM', allow_uboot_prompt=True)
		elif (self.__args.boardName == "rzv2h-evk" or self.__args.boardName == "imdt-v2h-sbc"):
			ok = self.__serialReadWithReconnect('Load Program to SRAM', allow_uboot_prompt=True)
		elif (self.__args.boardName == "rzv2h-rdk"):
			ok = self.__serialReadNoResponseWithReconnect()
		else:
			ok = self.__serialReadWithReconnect('please send !', allow_uboot_prompt=True)

		if not ok:
			die(msg='Failed to communicate with board after reconnection attempts.')

		# Write flash writer application
		time1 = time.time()
		print("\nWriting Flash Writer application...")
		self.__writeFileToSerial(self.__args.flashWriterImage)
		self.__serialRead('>')

		time2 = time.time()
		elapsed_time = time2 - time1
		print(f"Elapsed time: Flash Writer: {elapsed_time:.6f} seconds")
		print("Flash Writer has finished successfully.\n")

		self.__writeSerialCmd('')
		self.__serialRead('>')

		# emmc flash
		if (self.__args.flashMethod == "emmc"):
			self.__handle_emmc_flash(self.__flashAddress["emmc"])
		# xspi flash
		elif (self.__args.flashMethod == "xspi"):
			self.__handle_xspi_flash(self.__flashAddress["xspi"])

		print("Closed serial port.")
		self.__serialPort.close()

		end_time = time.time()
		elapsed_time = end_time - start_time
		print(f"Elapsed time: {elapsed_time:.6f} seconds")

	def __handle_emmc_flash(self, flashAddress):
		self.__writeSerialCmd('EM_E')
		self.__serialRead('Select area')
		self.__writeSerialCmd('1')
		self.__serialRead('>')

		# Changing speed to 921600 bps.
		self.__writeSerialCmd('SUP')
		self.__serialRead('the terminal.')

		self.__setupSerialPort_SUP()
		time.sleep(1)
		self.__writeSerialCmd('')
		self.__serialRead('>')

		# Write BL2/SPL
		ipl_label = self.__ipl_label()
		ipl_image = self.__ipl_image()
		ipl_flash_address = flashAddress[self.__ipl_config_key(flashAddress)]
		self.__writeSerialCmd('EM_W')
		self.__serialRead('Select area')
		self.__writeSerialCmd(ipl_flash_address[0])

		self.__serialRead('Please Input Start Address in sector')
		self.__writeSerialCmd(ipl_flash_address[1])

		self.__serialRead('Please Input Program Start Address')
		self.__writeSerialCmd(ipl_flash_address[2])
		self.__serialRead('please send !')

		print(f"Writing {ipl_label}...")
		self.__writeFileToSerial(ipl_image)
		self.__serialRead('>')
		print(f"{ipl_label} write complete.\n")

		# Write FIP
		FIPFlashAddress = flashAddress["FIP"]
		self.__writeSerialCmd('EM_W')
		self.__serialRead('Select area')
		self.__writeSerialCmd(FIPFlashAddress[0])

		self.__serialRead('Please Input Start Address in sector')
		self.__writeSerialCmd(FIPFlashAddress[1])

		self.__serialRead('Please Input Program Start Address')
		self.__writeSerialCmd(FIPFlashAddress[2])
		self.__serialRead('please send !')
		print("Writing FIP...")
		self.__writeFileToSerial(self.__args.fipImage)

		self.__serialRead('EM_W Complete!')
		print("FIP write completed.\n")

		# Write EXT_CSD
		self.__writeSerialCmd('EM_SECSD')
		self.__serialRead('Please Input EXT_CSD Index')
		self.__writeSerialCmd('B1')
		self.__serialRead('Please Input Value')
		self.__writeSerialCmd(FIPFlashAddress[3])
		self.__serialRead('>')

		self.__writeSerialCmd('EM_SECSD')
		self.__serialRead('Please Input EXT_CSD Index')
		self.__writeSerialCmd('B3')
		self.__serialRead('Please Input Value')
		self.__writeSerialCmd(FIPFlashAddress[4])
		self.__serialRead('>')

		# Write board identification
		BIDFlashAddress = flashAddress["BID"]
		self.__writeSerialCmd('EM_WB')
		self.__serialRead('Select area')
		self.__writeSerialCmd(BIDFlashAddress[0])

		self.__serialRead('Please Input Start Address in sector')
		self.__writeSerialCmd(BIDFlashAddress[1])

		self.__serialRead('Please Input File size(byte)')
		self.__writeSerialCmd(BIDFlashAddress[2])
		self.__serialRead('please send binary file!')

		print("Writing board identification...")
		self.__writeFileToSerial(self.__args.bidImage)
		self.__serialRead('>')
		print("Board identification write completed.\n")

	def __handle_xspi_flash(self, flashAddress):
		is_v4h = (self.__args.boardName == "sparrow-hawk")

		# XCS erase: skip for rzv2h-evk, rzv2h-rdk, and sparrow-hawk
		if not (self.__args.boardName == "rzv2h-evk") and not (self.__args.boardName == "rzv2h-rdk") and not (self.__args.boardName == "sparrow-hawk"):
			print("\n" + "="*SEPARATOR_WIDTH)
			print("** ERASING QSPI FLASH MEMORY **")
			print("="*SEPARATOR_WIDTH)
			print("This operation will erase the SpiFlash memory.")
			print("Please wait, this may take up to 60 seconds...")
			print("The terminal will appear to freeze during this time - this is normal.")
			print("="*SEPARATOR_WIDTH + "\n")

			self.__writeSerialCmd('XCS')
			self.__wait_for_prompt(60)

			print("\n" + "="*SEPARATOR_WIDTH)
			print("QSPI flash erase complete!")
			print("="*SEPARATOR_WIDTH + "\n")

		# Changing speed to 921600 bps.
		# NOTE: sparrow-hawk Flash Writer runs at 921600 from power-on,
		# the SUP command is not supported (returns "command not found"),
		# so skip it entirely.
		if not is_v4h:
			self.__writeSerialCmd('SUP')
			self.__serialRead('the terminal.')
			self.__setupSerialPort_SUP()
			time.sleep(1)
			self.__writeSerialCmd('')
			self.__serialRead('>')

		if is_v4h:
			# V4H: Flash Writer Rev.77.9.4 XLS2 has unreliable SREC→SPI
			# address mapping; use XLS3 (binary mode, 128KB chunks)
			# which matches the reference ipl_burning.py behaviour.
			# The FW already runs at 921600, no SUP needed.
			self.__write_binary_chunked_xls3(
				"SPL (SA0+SPL)", self.__ipl_image(), int(flashAddress[self.__ipl_config_key(flashAddress)][1], 16))
			self.__write_binary_chunked_xls3(
				"FIP (FIT)", self.__args.fipImage, int(flashAddress["FIP"][1], 16))
		else:
			# Write BL2
			BL2FlashAddress = flashAddress["BL2"]
			self.__writeSerialCmd('XLS2')
			self.__serialRead('Please Input : H')
			self.__writeSerialCmd(BL2FlashAddress[0])

			self.__serialRead('Please Input : H')
			self.__writeSerialCmd(BL2FlashAddress[1])
			self.__serialRead('please send !')

			print("Writing BL2...")
			self.__writeFileToSerial(self.__args.bl2Image)
			self.__wait_for_prompt(self.__prompt_timeout_for_file(self.__args.bl2Image))
			print("BL2 write complete.\n")

			# Write FIP
			FIPFlashAddress = flashAddress["FIP"]
			self.__writeSerialCmd('XLS2')
			self.__serialRead('Please Input : H')
			self.__writeSerialCmd(FIPFlashAddress[0])

			self.__serialRead('Please Input : H')
			self.__writeSerialCmd(FIPFlashAddress[1])
			self.__serialRead('please send !')

			print("Writing FIP...")
			self.__writeFileToSerial(self.__args.fipImage)
			self.__wait_for_prompt(self.__prompt_timeout_for_file(self.__args.fipImage))
			print("FIP write completed.\n")

		# Write PCIe PHY firmware (rcar_gen4_pcie.bin), if provided
		if self.__args.pcieFwImage:
			PcieFlashAddress = flashAddress["PCIE"]
			self.__write_binary_chunked_xls3(
				"PCIe firmware (rcar_gen4_pcie.bin)", self.__args.pcieFwImage, int(PcieFlashAddress[0], 16))

		# Write board identification
		BIDFlashAddress = flashAddress["BID"]
		if (self.__args.bidImage.endswith('.srec')):
			self.__writeSerialCmd('XLS2')
		else:
			self.__writeSerialCmd('XLS3')
		self.__serialRead('Please Input : H')
		self.__writeSerialCmd(BIDFlashAddress[0])

		self.__serialRead('Please Input : H')
		self.__writeSerialCmd(BIDFlashAddress[1])
		self.__serialRead('please send !')

		print("Writing board identification...")
		self.__writeFileToSerial(self.__args.bidImage)
		self.__wait_for_prompt()
		print("Board identification write completed.\n")

	def __write_binary_chunked_xls3(self, label, file_path, flash_offset):
		"""Write a raw binary file to xSPI via xls3, chunked in 128KB blocks."""
		chunk_size = 128 * 1024
		total_size = os.path.getsize(file_path)
		import math
		total_chunks = math.ceil(total_size / chunk_size)

		print(f"Writing {label} — {total_size} bytes in {total_chunks} chunks...")

		with open(file_path, "rb") as f:
			offset = flash_offset
			while True:
				chunk = f.read(chunk_size)
				if not chunk:
					break

				self.__writeSerialCmd('')
				self.__wait_for_prompt(30)
				self.__writeSerialCmd('XLS3')

				self.__serialRead('Please Input : H')
				size_hex = f"{len(chunk):X}"
				self.__writeSerialCmd(size_hex)

				self.__serialRead('Please Input : H')
				offset_hex = f"{offset:X}"
				self.__writeSerialCmd(offset_hex)

				self.__serialRead('please send !')

				self.__serialPort.write(chunk)
				self.__wait_for_prompt(30)

				offset += len(chunk)

		print(f"{label} write completed.\n")

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

	def __serialReadNoResponseWithReconnect(self, max_retries=MAX_RECONNECT_RETRIES) -> bool:
		"""Read from a serial without any response with automatic reconnection on failure.

		Args:
			max_retries: Maximum number of retry attempts
		"""
		self.__initialConnection = True
		wait_start = time.time()

		for attempt in range(max_retries):
			try:
				while self.__initialConnection:
					ports = [port.device for port in comports()]

					# Wait until the originally selected port is lost
					if self.__oldPort in ports:
						if time.time() - wait_start > WAIT_POWER_TIMEOUT:
							print(f"Timeout waiting for serial port {self.__oldPort} to disconnect.")
							return False
						time.sleep(0.5)
						continue

					self.__initialConnection = False

				# Need reconnection
				if attempt < max_retries - 1:
					if self._reconnect_serial():
						return True

			except Exception as e:
				print(f"Unexpected error: {type(e).__name__}: {e}")
				return False

		print(f"Failed to communicate with board after {max_retries} attempts.")
		return False

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

	def __writeSerialCmd(self, cmd):
		self.__serialPort.write(f'{cmd}\r'.encode())

	# Function to write file over serial
	def __writeFileToSerial(self, file):
		# Large files (e.g. sparrow-hawk's ~5MB FIP SREC) sent in one write()
		# call can outrun the Flash Writer's ability to drain its UART FIFO
		# into QSPI, since this link has no flow control (no RTS/CTS,
		# no XON/XOFF). Sending in small chunks with a short pause lets the
		# receiver keep up instead of silently dropping/corrupting bytes.
		chunk_size = 4096
		with open(file, 'rb') as f:
			while True:
				chunk = f.read(chunk_size)
				if not chunk:
					break
				self.__serialPort.write(chunk)
				self.__serialPort.flush()
				time.sleep(0.005)

	# Function to wait and print contents of serial buffer
	def __serialRead(self, cond='\n', timeout=10, retry_interval=1):
		"""
		Read data from the serial port until the condition string 'cond' is encountered or the timeout is reached.

		Parameters:
		- cond: The condition string to stop reading (default is '\n').
		- timeout: Maximum wait time (in seconds) before raising an error if no data is received.
		- retry_interval: Time interval between retry attempts (in seconds).

		Returns:
		- Data read from the serial port.
		"""
		start_time = time.time()
		while time.time() - start_time < timeout:
			try:
				# Attempt to read data from the serial port
				buf = self.__serialPort.read_until(cond.encode())

				if not buf:
					print(f"Returned value {cond} is not the expectation. Exiting.")
					exit()

				print(f'{buf.decode(errors="ignore")}')
				return buf

			except serial.SerialException as e:
				# If the error is due to a disconnection
				if "device reports readiness to read but returned no data" in str(e):
					print(f"Device disconnected. Retrying in {retry_interval} seconds...")
					time.sleep(retry_interval)  # Wait before retrying
				else:
					# If it's another error, re-raise the exception
					raise serial.SerialException(f"read failed: {e}")

		# If the timeout is reached without a connection, raise an error
		raise serial.SerialException("Device disconnected and did not reconnect within 10 seconds")

	def __setupSDCardDrive(self):
		if self.__sdCardDevice:
			return self.__sdCardDevice

		if not self.__args.esdDevice:
			die(msg='--esd_device must be provided when using the eSD flash method.')

		self.__sdCardDevice = self.__args.esdDevice
		return self.__sdCardDevice

	def writeBootloaderESD(self):
		target_device = self.__setupSDCardDrive()

		self.__validate_dd_tool()

		# Check file exists and is .bin
		ipl_esd_image = self.__ipl_esd_image()
		ipl_image = self.__ipl_image()
		self.__resolve_bin_image(ipl_esd_image)
		self.__resolve_bin_image(ipl_image)
		self.__resolve_bin_image(self.__args.fipImage)
		self.__resolve_bin_image(self.__args.bidImage)

		esd_config = self.__flashAddress["esd"]
		if esd_config is None:
			die(msg=f'eSD flash is not configured for board {self.__args.boardName}.')

		# Run dd to flash images
		print(f"Flashing eSD on device {target_device}...")
		esd_bp_key = "SPL_BP_ESD" if self.__is_v4h() else "BL2_BP_ESD"
		esd_ipl_key = self.__ipl_config_key(esd_config)
		self.__run_dd(ipl_esd_image, target_device, esd_config[esd_bp_key][0], esd_config[esd_bp_key][1])
		self.__run_dd(ipl_image, target_device, esd_config[esd_ipl_key][0])
		self.__run_dd(self.__args.bidImage, target_device, esd_config["BID"][0])
		self.__run_dd(self.__args.fipImage, target_device, esd_config["FIP"][0])

		self.__finalize_esd_flash(target_device)
		print("Completed eSD flashing. You can safely remove the SD card once the device is unmounted.")

	def __run_dd(self, source, target_device, seek, count=None):
		cmd = [self.__dd, f"if={source}", f"of={target_device}", f"seek={seek}", "bs=512", "conv=fsync"]
		if count:
			cmd.append(f"count={count}")

			# Check for sudo/admin privileges
			if platform.system() == "Linux":
				if os.geteuid() != 0:
					print("\n" + "=" * SEPARATOR_WIDTH)
					print("eSD flashing requires elevated privileges to write to a raw device.")
					print("The script will invoke 'sudo' for the dd command only.")
					print("=" * SEPARATOR_WIDTH)
					cmd = ["sudo"] + cmd

			elif platform.system() == "Windows":
				import ctypes
				if not ctypes.windll.shell32.IsUserAnAdmin():
					print("="*SEPARATOR_WIDTH)
					print("ERROR: eSD flashing requires Administrator privileges on Windows.")
					print("="*SEPARATOR_WIDTH)
					print("Please open Command Prompt or PowerShell as Administrator,")
					print("then run the script again.")
					print("="*SEPARATOR_WIDTH)
					sys.exit(1)

			print(f"Executing: {' '.join(cmd)}")
		try:
			subprocess.run(cmd, check=True)
		except FileNotFoundError:
			die(msg=f'dd command not found at {self.__dd}.')
		except subprocess.CalledProcessError as exc:
			die(msg=f'dd command failed with exit code {exc.returncode} while flashing {source}.')

	def __validate_dd_tool(self):
		if platform.system() == "Windows":
			if not os.path.exists(self.__dd):
				die(msg=f'dd executable not found at {self.__dd}.')
		else:
			if shutil.which(self.__dd) is None:
				die(msg='dd command not available on the system PATH.')

	def __resolve_bin_image(self, image_path):
		if not os.path.exists(image_path):
			die(msg=f'The file {image_path} does not exist.')
		if os.path.splitext(image_path)[1].lower() != '.bin':
			die(msg=f"The file {image_path} is not a .bin file and no matching .bin file was found. eSD flashing requires binaries in .bin format.")

	def __finalize_esd_flash(self, target_device):
		if platform.system() == "Windows":
			return

		try:
			subprocess.run(['sync'], check=True)
		except (FileNotFoundError, subprocess.CalledProcessError):
			print('Warning: Unable to run sync command.')

		try:
			subprocess.run(['eject', target_device], check=True)
		except (FileNotFoundError, subprocess.CalledProcessError):
			print(f'Warning: Unable to eject {target_device}. Please eject it manually if required.')

# Util function to die with error
def die(msg='', code=1):
	print(f'Error: {msg}')
	exit(code)

def main():
	bootloaderFlashUtil = BootloaderFlashUtil()

	if bootloaderFlashUtil.flashMethod == 'esd':
		bootloaderFlashUtil.writeBootloaderESD()
	else:
		bootloaderFlashUtil.setupSerialPort()
		bootloaderFlashUtil.writeBootloader()

if __name__ == '__main__':
	main()
