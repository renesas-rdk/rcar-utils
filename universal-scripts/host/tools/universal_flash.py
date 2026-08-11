import sys
import os
import json
import argparse
import glob
import platform
import subprocess
from dataclasses import dataclass
from string import ascii_uppercase
from serial.tools.list_ports import comports

# Importing utility applications
sys.path.append(os.path.join(os.path.dirname(__file__), 'firmware_compile'))
sys.path.append(os.path.join(os.path.dirname(__file__), 'bootloader_flasher'))
sys.path.append(os.path.join(os.path.dirname(__file__), 'sd_creator'))
sys.path.append(os.path.join(os.path.dirname(__file__), 'uload_bootloader'))
from firmware_compile import FirmwareBuilder, parse_args
from bootloader_flash import BootloaderFlashUtil
from sd_flash import SdFlashUtil
from uload_bootloader_flash import UloadFlashUtil

try:
    import tomllib as tomli
except ImportError:
    try:
        import tomli
    except ImportError:
        print("ERROR: Neither tomllib (Python >=3.11) nor tomli package is available.")
        print("Please install tomli: pip install tomli")
        print("Or use Python 3.11 or later which includes tomllib.")
        sys.exit(1)

# Constants
MESSAGE_WIDTH = 85
# Fixed baud rate for serial communication (U-Boot console requires 115200)
DEFAULT_BAUD_RATE = 115200
# Sparrow-hawk (V4H) Flash Writer/CR52 loader talks at 921600 from power-on,
# with no 115200 auto-baud stage like the V2H/G2L boards.
SPARROW_HAWK_BAUD_RATE = 921600

script_name = os.path.basename(sys.argv[0])

@dataclass
class FlashInfo:
    board_identification: str
    flash_writer: str
    ipl_flash_method: str
    rootfs: str
    rootfs_flash_method: str
    spl: str = ""
    bl2: str = ""
    fip: str = ""
    uboot_fit: str = ""
    pcie_fw: str = ""

class UniversalFlashUtil:
    def __init__(self):
        self.__scriptDir = os.path.dirname(os.path.abspath(__file__))
        self.__rootDir = os.path.abspath(os.path.join(self.__scriptDir, '..', '..'))
        self.__imagesDir = os.path.abspath(os.path.join(self.__rootDir, 'target', 'images'))
        self.json_file = os.path.join(self.__scriptDir, "flash_images.json")
        self.boards_data = {}
        self.board_config = {}
        self.selected_port = None
        self.selected_port_by_id = None  # For reliable reconnection after power cycle
        self.selected_baud_rate = 115200
        self.selected_board_name = None
        self.selected_ip_address = "169.254.187.89"
        self.selected_info = None

        # Ensure bpgen and fiptool are executable
        self._ensure_tools_executable()

    def _ensure_tools_executable(self):
        """Make bpgen and fiptool executable if they exist"""
        import platform
        import stat

        # Determine OS-specific bin directory
        os_name = platform.system().lower()
        if os_name == "linux":
            bin_dir = os.path.join(self.__scriptDir, 'bin', 'linux')
        elif os_name == "windows":
            bin_dir = os.path.join(self.__scriptDir, 'bin', 'windows')
        else:
            return  # Unknown OS, skip

        tools = ['bpgen', 'fiptool', 'mkimage']
        for tool in tools:
            tool_path = os.path.join(bin_dir, tool)
            if os.path.exists(tool_path):
                try:
                    # Add execute permission for owner, group, and others
                    current_permissions = os.stat(tool_path).st_mode
                    os.chmod(tool_path, current_permissions | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
                except Exception as e:
                    print(f"Warning: Could not set execute permission for {tool}: {e}")

    def _get_by_id_path(self, tty_device: str) -> str:
        """Get the /dev/serial/by-id/ path for a given tty device.
        This allows reliable reconnection after power cycle."""
        by_id_dir = "/dev/serial/by-id"
        if not os.path.exists(by_id_dir):
            return tty_device

        device_name = os.path.basename(tty_device)

        try:
            for by_id_link in glob.glob(os.path.join(by_id_dir, "*")):
                real_path = os.path.realpath(by_id_link)
                if os.path.basename(real_path) == device_name:
                    return by_id_link
        except Exception as e:
            print(f"Warning: Could not resolve by-id path: {e}")

        return tty_device

    def load_json(self):
        try:
            with open(self.json_file, 'r') as f:
                self.boards_data = json.load(f)
        except FileNotFoundError:
            print(f"File '{self.json_file}' not found.")
        except json.JSONDecodeError as e:
            print(f"Error decoding JSON: {e}")

    def load_board_config(self):
        """Load board configuration from TOML file"""
        try:
            config_path = os.path.join(self.__scriptDir, 'config', 'boards_flash_config.toml')
            with open(config_path, 'rb') as f:
                self.board_config = tomli.load(f)
        except FileNotFoundError:
            print(f"Warning: Board configuration file not found.")
        except Exception as e:
            print(f"Warning: Error loading board config: {e}")

    def input_board_selection(self):
        # Board selection
        if not self.boards_data:
            print("No board data loaded.")
            return False

        print("Available boards:")
        for idx, board in enumerate(self.boards_data.keys()):
            print(f"{idx + 1}. {board}")

        board_names = list(self.boards_data.keys())
        try:
            selection = int(input("Select board by number: ")) - 1
            if selection < 0 or selection >= len(board_names):
                print("Invalid selection.")
                return False
            self.selected_board_name = board_names[selection]
            print(f"Selected board: {self.selected_board_name}\n")
            return True
        except (ValueError, KeyboardInterrupt):
            print("\nOperation cancelled by user.")
            return False

    def input_serial_selection(self):
        ports = [p.device for p in comports()]
        if not ports:
            return False
        print("Available serial ports:")
        for i, port in enumerate(ports):
            print(f"{i}: {port}")

        try:
            index = int(input(f"Select a port by number (Default {ports[0]}): ") or 0)
            if 0 <= index < len(ports):
                self.selected_port = ports[index]
                # Get by-id path for reliable reconnection
                self.selected_port_by_id = self._get_by_id_path(self.selected_port)
            else:
                print("Invalid number. Try again.")
                return False
        except (ValueError, KeyboardInterrupt):
            print("\nOperation cancelled by user.")
            return False

        # This is the IPL Flash Writer baud rate.  Sparrow-Hawk's CR52 Flash
        # Writer talks at 921600 from power-on; its normal U-Boot console is
        # still 115200 and is selected separately for rootfs flashing below.
        if self.selected_board_name == "sparrow-hawk":
            self.selected_baud_rate = SPARROW_HAWK_BAUD_RATE
        else:
            self.selected_baud_rate = DEFAULT_BAUD_RATE
        
        print(f"Selected port [{self.selected_port}] with baud rate: {self.selected_baud_rate}")
        if self.selected_port_by_id and self.selected_port_by_id != self.selected_port:
            print(f"Device ID path: {self.selected_port_by_id}")
        print()
        return True

    def select_ipl_method(self):
        options = {
            1: "BootloaderFlash",
            2: "UloadFlash"
        }

        print("Write IPL method:")
        for key, value in options.items():
            print(f"{key}. {value}")

        while True:
            try:
                choice = int(input("Select write IPL method by number: "))
                return options[choice]
            except ValueError:
                print("Invalid input. Please enter a number.")

    def prepare_binaries(self):
        print("\n=== Building firmware artifacts ===")

        # Map paths from images dir + flash_images.json
        board_soc = self.boards_data[self.selected_board_name]["soc"]

        if board_soc == "v4h":
            # Compose the selected board's FIT from Yocto's common U-Boot
            # executable and board-specific U-Boot DTB.
            raw_sa0 = os.path.join(self.__imagesDir, "u-boot", "sa0.bin")
            uboot_nodtb = os.path.join(self.__imagesDir, "u-boot", "u-boot-nodtb-rz-cmn.bin")
            uboot_dtb = os.path.join(
                self.__imagesDir, "u-boot", "dtbs",
                self.boards_data[self.selected_board_name]["uboot_dtb"])
            args = parse_args([
                "--board", self.selected_board_name,
                "--soc", "v4h",
                "--method", self.boards_data[self.selected_board_name]["ipl_flash_method"],
                "--spl", raw_sa0,
                "--u-boot-nodtb", uboot_nodtb,
                "--uboot-dtbs", uboot_dtb,
                "--out-dir", self.__imagesDir,
            ])
            FirmwareBuilder(args).run_all_v4h()
            return

        bl2_path = os.path.join(self.__imagesDir, "atf", f"bl2-{self.selected_info.ipl_flash_method}-rz-cmn.bin")
        bl31_path = os.path.join(self.__imagesDir, "atf", "bl31-rz-cmn.bin")
        atf_fdts_path = os.path.join(self.__imagesDir, "atf", "fdts", self.boards_data[self.selected_board_name]['atf_fdts'])
        uboot_dtbs_path = os.path.join(self.__imagesDir, "u-boot", "dtbs", self.boards_data[self.selected_board_name]['uboot_dtb'])
        uboot_nodtb_path = os.path.join(self.__imagesDir, "u-boot", "u-boot-nodtb-rz-cmn.bin")

        # Build the args namespace exactly as firmware-compile expects
        args = parse_args([
            "--board", self.selected_board_name,
            "--soc", board_soc,
            "--method", self.boards_data[self.selected_board_name]["ipl_flash_method"],
            "--bl2", bl2_path,
            "--atf-fdts", atf_fdts_path,
            "--uboot-dtbs", uboot_dtbs_path,
            "--bl31", bl31_path,
            "--u-boot-nodtb", uboot_nodtb_path,
            #"--out-dir", os.path.join(self.__imagesDir, "build_artifacts") # it depends, it can be deployed to target/images or custom dir.
        ])

        builder = FirmwareBuilder(args)
        builder.run_all()

    def info_get(self):
        board_data = self.boards_data[self.selected_board_name]

        self.selected_info = FlashInfo(
            board_identification=board_data["board_identification"],
            flash_writer=board_data["flash_writer"],
            ipl_flash_method=board_data["ipl_flash_method"],
            rootfs=board_data["rootfs"],
            rootfs_flash_method=board_data["rootfs_flash_method"],
            spl=board_data.get("spl", ""),
            bl2=board_data.get("bl2", ""),
            fip=board_data.get("fip", ""),
            uboot_fit=board_data.get("uboot_fit", ""),
            pcie_fw=board_data.get("pcie_fw", ""),
        )

    def print_selected_info(self):
        if not self.selected_info:
            print("No board selected.")
            return

        print(f"\nSelected Board: {self.selected_board_name}")
        print("Board Information:")
        if self.selected_info.spl:
            print(f"  SPL: {self.selected_info.spl}")
        else:
            print(f"  BL2: {self.selected_info.bl2}")
        if self.selected_info.uboot_fit:
            print(f"  U-Boot FIT: {self.selected_info.uboot_fit}")
        print(f"  Board Identification: {self.selected_info.board_identification}")
        print(f"  Flash Writer: {self.selected_info.flash_writer}")
        print(f"  IPL Flash Method: {self.selected_info.ipl_flash_method}")
        print(f"  Rootfs Flash Method: {self.selected_info.rootfs_flash_method}")
        print(f"  Rootfs: {self.selected_info.rootfs}")

    def yes_no_prompt(self, message: str) -> bool:
        while True:
            answer = input(f"{message} (y/n): ").strip().lower()
            if answer in ['y', 'yes']:
                return True
            elif answer in ['n', 'no']:
                return False
            else:
                print("Please enter 'y' or 'n'.")

    def detect_esd_devices(self):
        devices = []
        system = platform.system()
        if system == "Linux":
            import subprocess

            # Get all potential SD card devices
            all_devices = []
            all_devices.extend(sorted(glob.glob('/dev/sd[a-z]')))
            all_devices.extend(sorted(glob.glob('/dev/mmcblk[0-9]')))

            # Filter out only the root/system disk
            for device in all_devices:
                try:
                    # Check if device is the root filesystem
                    result = subprocess.run(['lsblk', '-no', 'MOUNTPOINT', device],
                                        capture_output=True, text=True, timeout=5)
                    mountpoints = result.stdout.strip()

                    if '/' in mountpoints.split('\n'):
                        continue

                    devices.append(device)
                except Exception:
                    print(f"Warning: failed to validate device {device}: {e}. Skipping it.")

        elif system == "Windows":
            try:
                import ctypes
                mask = ctypes.windll.kernel32.GetLogicalDrives()
                for letter in ascii_uppercase:
                    if mask & 1:
                        drive_path = f"{letter}:"
                        drive_type = ctypes.windll.kernel32.GetDriveTypeW(f"{letter}:\\")
                        if drive_type == 2:
                            devices.append(drive_path)
                    mask >>= 1
            except Exception:
                print(f"Failed to detect removable drives on Windows: {e}")

        return devices

    def prompt_esd_device(self):
        candidates = self.detect_esd_devices()
        selection = None
        if candidates:
            print("Available removable drives:")
            for idx, device in enumerate(candidates, start=1):
                print(f"  {idx}. {device}")
            while selection is None:
                choice = input("Select drive by number: ").strip()
                if not choice:
                    break
                try:
                    choice_idx = int(choice) - 1
                    if 0 <= choice_idx < len(candidates):
                        selection = candidates[choice_idx]
                    else:
                        print("Invalid selection. Please choose a listed number.")
                except ValueError:
                    print("Invalid selection. Please choose a listed number.")
        if not selection:
            print("No SD card device provided. Aborting eSD flashing.")
            return None
        return selection

    def run(self):
        self.load_json()
        self.load_board_config()
        if not self.input_board_selection():
            return
        # Get information for the selected board
        self.info_get()

        # Route to appropriate workflow based on flash method
        if self.selected_info.ipl_flash_method == "esd":
            self.run_esd_workflow()
        elif self.selected_info.ipl_flash_method in ["xspi", "emmc"]:
            self.run_serial_workflow()
        else:
            print(f"Unsupported IPL flash method: {self.selected_info.ipl_flash_method}")
            return

    def run_esd_workflow(self):
        """Dedicated workflow for eSD flashing

        Flow:
        1. Flash rootfs to SD card (requires board connection via serial/UDP/OTG)
        2. Power off board and swap SD card to host PC
        3. Flash bootloader to SD card
        4. Done - insert SD card back to board and boot
        """
        print("\n" + "="*MESSAGE_WIDTH)
        print("eSD FLASHING MODE")
        print("="*MESSAGE_WIDTH)
        print("This workflow flashes rootfs first, then bootloader.")
        print("SD card will need to be swapped between board and host PC.")
        print("="*MESSAGE_WIDTH + "\n")

        # Flash rootfs (requires board connection)
        if self.yes_no_prompt("Step 1: Do you want to flash the rootfs to SD card?"):
            print("Flashing rootfs requires board connection via serial/UDP/OTG.\n")

            # Serial port selection for rootfs flashing
            ret = self.input_serial_selection()
            if not ret:
                print("No serial ports detected. Please connect your board and try again.")
                return
            self._flash_rootfs_serial()
        else:
            print("Skipping rootfs flashing.")
            if not self.yes_no_prompt("Do you want to continue with bootloader flashing only?"):
                return

        # Prepare for bootloader flashing
        print("\n" + "="*MESSAGE_WIDTH)
        print("BOOTLOADER FLASHING - SD CARD SWAP REQUIRED")
        print("="*MESSAGE_WIDTH)
        print("\nPlease follow these steps:")
        print("1. Power OFF the board")
        print("2. Remove the SD card from the board")
        print("3. Insert the SD card into the host PC")
        print("="*MESSAGE_WIDTH + "\n")

        # Check for sudo/admin privileges for eSD flashing
        if platform.system() == "Linux":
            if os.geteuid() != 0:
                print("eSD flashing requires root privileges. Please run the script with sudo or as root.")
                return False
        elif platform.system() == "Windows":
            import ctypes
            if not ctypes.windll.shell32.IsUserAnAdmin():
                print("eSD flashing requires administrator privileges. Please run as Administrator.")
                return False

        # Flash bootloader to SD card
        if self.yes_no_prompt("Do you want to flash the bootloader to SD card?"):
            print("Writing bootloader by eSD flash...\n")
            self.prepare_binaries()

            esd_device = self.prompt_esd_device()
            if not esd_device:
                print("Skipping eSD bootloader flashing: no SD card device selected.")
                return

            print("\n" + "=" * MESSAGE_WIDTH)
            print("WARNING: DESTRUCTIVE OPERATION")
            print("=" * MESSAGE_WIDTH)
            print(f"You are about to write bootloader data to raw device: {esd_device}")
            print("Existing data on the selected device may be overwritten or corrupted.")
            print("Make sure the selected device is the correct SD card.")
            print("=" * MESSAGE_WIDTH)

            if not self.yes_no_prompt(f"Proceed with flashing the bootloader to {esd_device}?"):
                return

            self._flash_bootloader_esd(esd_device)
        else:
            print("Skipping bootloader flashing.")
            return

        print("\n" + "="*MESSAGE_WIDTH)
        print("SD card flashing complete!")
        print("="*MESSAGE_WIDTH)
        print("\nNext steps:")
        print("1. Safely eject the SD card from the host PC")
        print("2. Insert the SD card into the board")
        print("3. Power on the board")
        print("="*MESSAGE_WIDTH + "\n")

    def run_serial_workflow(self):
        """Workflow for QSPI/eMMC flashing"""
        # Serial port selection
        ret = self.input_serial_selection()
        if not ret:
            print("No serial ports detected. Please connect your board and try again.")
            return

        # Write IPL
        if self.yes_no_prompt("Do you want to write the IPL?"):
            ipl_method = self.select_ipl_method()

            if ipl_method == "BootloaderFlash":
                print("Writing IPL by bootloader flash...\n")
                self.prepare_binaries()
                self._flash_bootloader_serial()
            else:  # UloadFlash
                print("Writing IPL by Uload bootloader...\n")
                self._flash_uload_bootloader()

        # Write Rootfs
        if self.yes_no_prompt("Do you want to write the rootfs?"):
            self._flash_rootfs_serial()

    def resolve_device(self, device):
        import platform
        import subprocess
        import re

        if platform.system() == "Windows":
            if device.startswith(r'\\.\PhysicalDrive'):
                return device

            if len(device) == 2 and device[1] == ':':
                drive_letter = device[0]

                try:
                    cmd = f'wmic logicaldisk where "DeviceID=\'{device}\'" get VolumeName, DeviceID'
                    subprocess.check_output(cmd, shell=True)

                    # Get disknumber
                    ps_cmd = f"(Get-Partition -DriveLetter {drive_letter}).DiskNumber"
                    disk_number = subprocess.check_output(
                        ["powershell", "-Command", ps_cmd],
                        text=True
                    ).strip()

                    raw_device = f'\\\\.\\PhysicalDrive{disk_number}'
                    print(f"[INFO] {device} → {raw_device}")

                    return raw_device

                except Exception as e:
                    print(f"[ERROR] Failed to resolve {device}: {e}")
                    return f'\\\\.\\{device}'

            return device

        return device

    def _flash_bootloader_esd(self, esd_device):
        """Flash bootloader to SD card via eSD method"""

        raw_device = self.resolve_device(esd_device)

        bootloader_args = [
            '--board_name', self.selected_board_name,
            '--flash_method', 'esd',
            '--image_fip', f"{self.__imagesDir}/fip_{self.selected_board_name}.bin",
            '--image_bid', f"{self.__imagesDir}/{self.selected_info.board_identification}",
            '--esd_device', raw_device
        ]
        bootloader_args += [
            '--image_bl2', f"{self.__imagesDir}/bl2_{self.selected_board_name}.bin",
            '--image_bl2_esd', f"{self.__imagesDir}/bl2_bp_esd_{self.selected_board_name}.bin",
        ]

        bootloaderFlashUtil = BootloaderFlashUtil(args=bootloader_args)
        bootloaderFlashUtil.writeBootloaderESD()
        print("Bootloader flashing complete.\n")

    def _flash_bootloader_serial(self):
        """Flash bootloader via serial connection"""
        bootloader_args = [
            '--board_name', f"{self.selected_board_name}",
            '--flash_method', f"{self.selected_info.ipl_flash_method}",
            '--serial_port', f"{self.selected_port}",
            '--serial_port_baud', f"{self.selected_baud_rate}",
            '--image_writer', f"{self.__imagesDir}/{self.selected_info.flash_writer}",
            '--image_bid', f"{self.__imagesDir}/{self.selected_info.board_identification}"
        ]

        if self.selected_info.spl:
            bootloader_args += ['--image_spl', f"{self.__imagesDir}/{self.selected_info.spl}"]
        if self.selected_info.bl2:
            bootloader_args += ['--image_bl2', f"{self.__imagesDir}/{self.selected_info.bl2}"]
        if self.selected_info.fip:
            bootloader_args += ['--image_fip', f"{self.__imagesDir}/{self.selected_info.fip}"]
        if self.selected_info.uboot_fit:
            bootloader_args += [
                '--image_uboot_fit',
                f"{self.__imagesDir}/{self.selected_info.uboot_fit}"
            ]
        if self.selected_info.pcie_fw:
            bootloader_args += ['--image_pcie_fw', f"{self.__imagesDir}/{self.selected_info.pcie_fw}"]

        if self.selected_port_by_id:
            bootloader_args.extend(['--serial_port_by_id', self.selected_port_by_id])

        bootloaderFlashUtil = BootloaderFlashUtil(args=bootloader_args)
        bootloaderFlashUtil.setupSerialPort()
        bootloaderFlashUtil.writeBootloader()

    def _flash_uload_bootloader(self):
        """Flash uload bootloader via serial"""
        uload_baud_rate = (DEFAULT_BAUD_RATE if self.selected_board_name == "sparrow-hawk"
                           else self.selected_baud_rate)
        uload_bootloader_args = [
            '--board_name', self.selected_board_name,
            '--serial_port', self.selected_port,
            '--serial_port_baud', f"{uload_baud_rate}",
            '--image_bid', f"{self.selected_info.board_identification}"
        ]
        if self.selected_info.uboot_fit:
            uload_bootloader_args += ['--uboot_fit_path', self.selected_info.uboot_fit]

        uloadFlashUtil = UloadFlashUtil(args=uload_bootloader_args)
        uloadFlashUtil.writeUloadBootloader()

    def _resolve_rootfs_image(self):
        configured = os.path.join(self.__imagesDir, self.selected_info.rootfs)
        if not os.path.isfile(configured):
            raise FileNotFoundError(
                f"Configured rootfs image is missing for {self.selected_board_name}: "
                f"{configured}"
            )
        return configured

    def _flash_rootfs_serial(self):
        """Flash rootfs via serial (UDP/OTG fastboot)"""
        print("Writing rootfs...")

        # Rootfs flashing talks to U-Boot in normal boot mode, not to the
        # Flash Writer.  U-Boot's console is 115200 on every supported board,
        # including Sparrow-Hawk (whose IPL Flash Writer requires 921600).
        rootfs_baud_rate = DEFAULT_BAUD_RATE
        if self.selected_baud_rate != rootfs_baud_rate:
            print(f"Using U-Boot console baud rate for rootfs flashing: {rootfs_baud_rate}")

        # Prepare arguments for SD Flash
        sdflash_args = [
            '--board_name', f"{self.selected_board_name}",
            '--serial_port', f"{self.selected_port}",
            '--serial_port_baud', f"{rootfs_baud_rate}",
            '--fastboot_type', f"{self.selected_info.rootfs_flash_method}",
            '--image_rootfs', self._resolve_rootfs_image(),
        ]

        # Add by-id path for reliable reconnection after power cycle
        if self.selected_port_by_id:
            sdflash_args += ['--serial_port_by_id', self.selected_port_by_id]

        method = (self.selected_info.rootfs_flash_method or "").lower()

        if method == "udp":
            # Get ethernet port info from board config
            ethernet_port_info = ""
            ether_port = "1"  # default value
            available_ports = []

            if self.selected_board_name in self.board_config:
                board_cfg = self.board_config[self.selected_board_name]
                if 'ethernet_udp_index' in board_cfg:
                    udp_index = board_cfg['ethernet_udp_index']
                    if isinstance(udp_index, list):
                        # If multiple ports available, allow user to select
                        available_ports = [str(p) for p in udp_index]
                        ethernet_port_info = f" (Available ports: {', '.join(available_ports)})"
                    else:
                        ether_port = str(udp_index)
                        ethernet_port_info = f" (Using Ethernet port: {ether_port})"
                else:
                    print(f"Warning: 'ethernet_udp_index' not found in board config for {self.selected_board_name}. Using default port 1.")
                    ether_port = "1"
                    ethernet_port_info = " (default port index: 1)"
                    available_ports = []

            print(f"\n{'='*MESSAGE_WIDTH}")
            print(f"** IMPORTANT: Ethernet Connection Required **")
            print(f"{'='*MESSAGE_WIDTH}")
            print(f"Please connect an Ethernet cable between:")
            print(f"  - Host (PC or router) Ethernet port")
            print(f"  - Board Ethernet port{ethernet_port_info}")
            print(f"\nEnsure both devices are on the same network segment.")
            print(f"{'='*MESSAGE_WIDTH}\n")

            # If multiple ports are available, let user select
            if available_ports:
                print(f"Available Ethernet ports: {', '.join(available_ports)}")
                while True:
                    selected_port = input(f"Select Ethernet port (default {available_ports[0]}): ").strip() or available_ports[0]
                    if selected_port in available_ports:
                        ether_port = selected_port
                        break
                    else:
                        print(f"Invalid port. Please select from: {', '.join(available_ports)}")

            self.selected_ip_address = input(f"Enter IP address for fastboot udp (default {self.selected_ip_address}): ") or self.selected_ip_address

            sdflash_args += ['--ether_port', ether_port,
                        '--ip_address', self.selected_ip_address]
        elif method == "otg":
            # No Ethernet/IP options needed for OTG/USB fastboot
            print(f"\n{'='*MESSAGE_WIDTH}")
            print(f"** IMPORTANT: USB OTG Flashing Mode **")
            print(f"{'='*MESSAGE_WIDTH}")
            print(f"USB OTG flashing will be used to write the rootfs.")
            print(f"Ensure the board's USB OTG port is connected to the PC.")
            print(f"{'='*MESSAGE_WIDTH}\n")
        else:
            print(f"Unsupported rootfs flash method: '{self.selected_info.rootfs_flash_method}'")
            print(f"Supported methods are: 'udp' or 'otg'")
            return False

        sdFlashUtil = SdFlashUtil(args=sdflash_args)
        sdFlashUtil.writeRootfs()

    def _configure_udp_flashing(self, sdflash_args):
        """Configure UDP flashing parameters"""
        ether_port = "1"
        available_ports = []

        if self.selected_board_name in self.board_config:
            board_cfg = self.board_config[self.selected_board_name]
            if 'ethernet_udp_index' in board_cfg:
                udp_index = board_cfg['ethernet_udp_index']
                if isinstance(udp_index, list):
                    available_ports = [str(p) for p in udp_index]
                else:
                    ether_port = str(udp_index)

        if not available_ports and ether_port:
            available_ports = [ether_port]

        print(f"\n{'='*MESSAGE_WIDTH}")
        print("** IMPORTANT: Ethernet Connection Required **")
        print(f"{'='*MESSAGE_WIDTH}")
        print("Please connect an Ethernet cable between:")
        print("  - Host (PC or router) Ethernet port")
        print(f"  - Board Ethernet port (Available: {', '.join(available_ports)})")
        print("Ensure both devices are on the same network segment.")
        print(f"{'='*MESSAGE_WIDTH}\n")

        # Allow user to select port if multiple available
        if len(available_ports) > 1:
            print(f"Available Ethernet ports: {', '.join(available_ports)}")
            while True:
                selected_port = input(f"Select Ethernet port (default {available_ports[0]}): ").strip() or available_ports[0]
                if selected_port in available_ports:
                    ether_port = selected_port
                    break
                print(f"Invalid port. Please select from: {', '.join(available_ports)}")

        ip_address = input(f"Enter IP address for fastboot udp (default {self.selected_ip_address}): ") or self.selected_ip_address

        sdflash_args.extend(['--ether_port', ether_port, '--ip_address', ip_address])

def show_help():
    """Display help menu with options"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    readme_path = os.path.join(script_dir, "README.md")

    print("\n" + "="*MESSAGE_WIDTH)
    print("Universal Flash Tool - Help Menu")
    print("="*MESSAGE_WIDTH)
    print("\nOptions:")
    print("  1. View installation and setup instructions")
    print("  2. Run the flash tool")
    print("  3. Exit")
    print("="*MESSAGE_WIDTH)

    while True:
        try:
            choice = input("\nSelect an option (1-3): ").strip()

            if choice == "1":
                # Display README.md path
                if os.path.exists(readme_path):
                    os_name = platform.system()

                    # Determine which section to refer to based on OS
                    if os_name == "Windows":
                        prereq_section = "Prerequisites -> Python, Environment and Tool Dependencies -> Windows"
                    elif os_name == "Linux":
                        prereq_section = "Prerequisites -> Python, Environment and Tool Dependencies -> Linux"
                    else:
                        prereq_section = "Prerequisites section"

                    print("\n" + "="*MESSAGE_WIDTH)
                    print("Installation and Setup Instructions")
                    print("="*MESSAGE_WIDTH)
                    print(f"\nPlease refer to the README.md file for detailed instructions:")
                    print(f"\nFile path: {readme_path}")
                    print(f"\n** IMPORTANT: Before running the flash tool **")
                    print(f"You must install all prerequisite tools listed in:")
                    print(f"  README.md -> {prereq_section}")
                    print(f"\nThis includes:")
                    print(f"  - Python and required packages (pyserial, tomli)")
                    if os_name == "Linux":
                        print(f"  - Fastboot (android-tools-fastboot)")
                    elif os_name == "Windows":
                        print(f"  - WinUSB driver (via Zadig) for USB OTG flashing")
                    print("="*MESSAGE_WIDTH)

                    # Ask if user wants to continue to flash tool
                    continue_choice = input("\nDo you want to run the flash tool now? (y/n): ").strip().lower()
                    if continue_choice in ['y', 'yes']:
                        return True
                    else:
                        return False
                else:
                    print(f"\nError: README.md not found at {readme_path}")
                    return False
                    
            elif choice == "2":
                return True

            elif choice == "3":
                print("\nExiting...")
                return False

            else:
                print("Invalid choice. Please enter 1, 2, or 3.")

        except (KeyboardInterrupt, EOFError):
            print("\n\nOperation cancelled.")
            return False

def main():
    try:
        # Parse command line arguments
        parser = argparse.ArgumentParser(
            description='Universal Flash Tool for RZ and R-Car boards',
            add_help=False  # Disable default help to use custom help
        )
        parser.add_argument('--help', '-h', action='store_true', 
                          help='Show help menu with installation instructions')
        args = parser.parse_args()

        # If --help is provided, show help menu
        if args.help:
            if not show_help():
                sys.exit(0)

        # Run the flash tool
        universalFlashUtil = UniversalFlashUtil()
        universalFlashUtil.run()
    except KeyboardInterrupt:
        print("\n\nOperation cancelled by user.")
        sys.exit(0)
    except Exception as e:
        if "SerialException" in type(e).__name__ or "device disconnected" in str(e).lower():
            print("\n\nSerial connection lost or device disconnected.")
            print("Operation cancelled.")
            sys.exit(1)
        else:
            # Re-raise unexpected exceptions
            raise

if __name__ == '__main__':
    main()
