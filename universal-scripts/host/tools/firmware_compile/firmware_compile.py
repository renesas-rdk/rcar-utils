#!/usr/bin/env python3
"""
firmware_compile.py — Build board-specific bootloader artifacts.

Pipeline:
1) BL2+ATF-FDTs -> bl2_<board>.bin
2) Boot Parameter (bpgen) -> bl2_bp_<board>.bin
	- For G2L/V2L: MBR-style (0x55AA) sector created by bpgen
	- For V2H: structured AA55FFFF record(s) via bpgen --mode and --dest
	- (Optional) Append BL2(+FDTs) to BP for flows that expect BP+BL2 in one blob
	- Emit SREC with VMA from TOML or CLI override
3) RZ boards (RZ/G2L, RZ/V2L, RZ/V2H): U-Boot(nodtb)+DTBs -> u-boot_<board>.bin
4) RZ boards: FIP (fiptool) -> fip_<board>.bin and SREC
5) V4H: mkimage(U-Boot nodtb + selected board DTB) -> u-boot_<board>.itb and SREC

Inputs & Config:
- Artifacts typically reside under target/images/{atf|u-boot}
- Board/method-specific VMAs and BL2_DEST are loaded from boards_flash_config.toml
- Tools are discovered under tools/bin/<os>/ or PATH:
	* bpgen   (unified boot-parameter generator)
	* fiptool (TF-A)
	* mkimage (U-Boot FIT image tool)
	* objcopy (GNU binutils)

Notes:
- V2H requires BL2_DEST from TOML (destination address for bpgen --dest).
- G2L/V2L do not use --dest/--mode.
"""

from __future__ import annotations
import argparse, platform, shutil, subprocess, sys
from dataclasses import dataclass
from pathlib import Path
import json
from typing import Optional

# ---------- repo roots / dirs ----------
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2] if HERE.name == "firmware_compile" and HERE.parent.name == "tools" else HERE

BIN_DIRS = [
	REPO / "tools" / "bin",
	REPO / "host" / "tools" / "bin",
]
IMG_DIR = REPO / "target" / "images"

CFG_DIRS = [
	REPO / "host" / "tools" / "config" / "boards_flash_config.toml",
]

JSON_DIR = [
	REPO / "host" / "tools" / "flash_images.json",
]

# ---------- utils ----------
def host_os_dir() -> str:
	"""Return canonical host dir name used under tools/bin/<os>/ (linux/windows)."""
	return "windows" if "windows" in platform.system().lower() else "linux"

def find_tool(name: str) -> Path:
	"""Locate a tool binary under tools/bin/<os>/ or in PATH; raise if missing."""
	exe = f"{name}.exe" if host_os_dir() == "windows" else name
	for base in BIN_DIRS:
		cand = base / host_os_dir() / exe
		if cand.exists():
			return cand
	found = shutil.which(exe)
	if found:
		return Path(found)
	search_str = " or ".join(str((b / host_os_dir() / exe)) for b in BIN_DIRS)
	raise FileNotFoundError(f"Tool '{name}' not found at {search_str} or in PATH")

def cat_files(out_path: Path, *inputs: Path) -> None:
	"""Concatenate multiple binary files into out_path (mkdir parents as needed)."""
	out_path.parent.mkdir(parents=True, exist_ok=True)
	with open(out_path, "wb") as out_f:
		for inp in inputs:
			with open(inp, "rb") as in_f:
				shutil.copyfileobj(in_f, out_f)

def first_that_exists(*candidates: Path) -> Path | None:
	"""Return the first existing file from candidates, or None if none exist."""
	for c in candidates:
		if c and c.exists():
			return c
	return None

def load_toml(path: Path) -> dict:
	"""Load and parse TOML file into a dictionary using tomllib or tomli."""
	if sys.version_info >= (3, 11):
		import tomllib
	else:
		import tomli as tomllib
	with open(path, "rb") as f:
		return tomllib.load(f)

def load_board_cfg(board: str) -> tuple[dict, dict]:
	"""Return (board_cfg, all_cfg) from boards_flash_config.toml for a given board."""
	cfg_path = first_that_exists(*CFG_DIRS)
	if cfg_path and cfg_path.exists():
		allcfg = load_toml(cfg_path)
		return allcfg.get(board, {}), allcfg
	return {}, {}

def hex_norm(x: str | int) -> str:
	"""Normalize int/hex-ish string to uppercase '0x...'."""
	if isinstance(x, int):
		return f"0x{x:X}"
	s = str(x).strip()
	if s.lower().startswith("0x"):
		return f"0x{int(s,16):X}"
	return f"0x{int(s,16):X}"

@dataclass
class Tools:
	"""Paths to external tools used in the firmware build pipeline."""
	bootparameter: Optional[Path]
	fiptool: Optional[Path]
	mkimage: Optional[Path]
	objcopy: Path

class FirmwareBuilder:
	"""
	Build pipeline driver: BL2(+FDTs), Boot Parameter, U-Boot(+DTBs), FIP(+SREC).
	Resolves defaults from target/images and boards_flash_config.toml.
	"""

	def __init__(self, args: argparse.Namespace):
		"""Initialize build context: resolve inputs, outputs, tools, and VMAs."""
		self.board = args.board
		self.method = args.method
		self.json_file = first_that_exists(*JSON_DIR)
		self.boards_data = {}

		# Load json file data
		self.load_json()

		# Defaults derived from target/images + board
		self.soc = (args.soc or self.boards_data[self.board]["soc"] or "g2l").lower()
		self.bpgen_soc = self.soc
		self.method = (args.method or self.boards_data[self.board]["ipl_flash_method"] or "xspi").lower()
		if self.soc == "v4h" and self.method != "xspi":
			raise ValueError("R-Car V4H supports only the xSPI firmware artifact layout.")

		default_bl2   = IMG_DIR / "atf"    / f"bl2-{self.method}-rz-cmn.bin"
		default_bl31  = IMG_DIR / "atf"    / "bl31-rz-cmn.bin"
		default_uboot_dtbs = [IMG_DIR / "u-boot" / "dtbs" / f"{self.boards_data[self.board]['uboot_dtb']}"]
		default_ubnd  = IMG_DIR / "u-boot" / "u-boot-nodtb-rz-cmn.bin"
		default_sa0   = IMG_DIR / "u-boot" / "sa0.bin"

		# Resolve inputs (CLI overrides > defaults)
		self.bl2   = Path(args.bl2)  if args.bl2  else default_bl2
		if self.soc == "v4h":
			if args.atf_fdts:
				raise ValueError("--atf-fdts is not used for R-Car V4H")
			self.atf_fdts = []
		else:
			atf_dtb = self.boards_data[self.board].get("atf_fdts")
			if not atf_dtb and not args.atf_fdts:
				raise ValueError(f"atf_fdts is required for RZ board {self.board}")
			default_atf_fdts = (
				[IMG_DIR / "atf" / "fdts" / atf_dtb] if atf_dtb else []
			)
			self.atf_fdts = [Path(p) for p in (args.atf_fdts or default_atf_fdts)]
		self.uboot_dtbs = [Path(p) for p in (args.uboot_dtbs or default_uboot_dtbs)]
		self.bl31  = Path(args.bl31) if args.bl31 else default_bl31
		self.ubnd  = Path(args.u_boot_nodtb) if args.u_boot_nodtb else default_ubnd
		self.sa0_bin = Path(args.sa0_bin) if args.sa0_bin else default_sa0

		self.out_dir = Path(args.out_dir or "out").resolve()
		self.out_dir.mkdir(parents=True, exist_ok=True)

		# Tools (allow override)
		self.tools = Tools(
			bootparameter=(None if self.soc == "v4h" else
						   Path(args.bootparameter) if args.bootparameter else find_tool("bpgen")),
			fiptool=(None if self.soc == "v4h" else
					 Path(args.fiptool) if args.fiptool else find_tool("fiptool")),
			mkimage=(Path(args.mkimage) if args.mkimage else find_tool("mkimage")
					 if self.soc == "v4h" else None),
			objcopy=Path(args.objcopy) if args.objcopy else find_tool("objcopy"),
		)

		# Load board + method config from TOML
		board_cfg, _ = load_board_cfg(self.board)
		method_cfg = board_cfg.get(self.method, {}) if board_cfg else {}

		# Load board specific information from TOML file
		self.spl_dest = board_cfg.get("spl_dest")
		self.bl2_dest = board_cfg.get("bl2_dest")
		self.dtb_base = board_cfg.get("fconf_dtb_base")
		self.bl2_base = board_cfg.get("bl2_base")
		# Calculate bl2 padding limit. V4H's SA0 header carries its own
		# payload size, so bl2_base is absent from its TOML section.
		self.bl2_padded_limit = (int(self.dtb_base, 16) - int(self.bl2_base, 16)
								if self.bl2_base else None)

		# SPL/BL2 VMA get from toml unless overridden
		spl_arr = method_cfg.get("SPL")
		bl2_arr = method_cfg.get("BL2")
		if self.soc == "v4h":
			ipl_arr = spl_arr
			if args.spl_bp_vma:
				self.spl_bp_vma = hex_norm(args.spl_bp_vma)
			else:
				self.spl_bp_vma = hex_norm(ipl_arr[0])
		else:
			ipl_arr = bl2_arr
			if args.bl2_bp_vma:
				self.bl2_bp_vma = hex_norm(args.bl2_bp_vma)
			elif (self.method == "xspi"):
				self.bl2_bp_vma = hex_norm(ipl_arr[0])
			elif (self.method == "emmc"):
				self.bl2_bp_vma = hex_norm(ipl_arr[2])

		if self.soc == "v4h":
			uboot_fit_arr = method_cfg.get("UBOOT_FIT", [])
			if not uboot_fit_arr:
				raise ValueError(f"UBOOT_FIT is not configured for {self.board}/{self.method}")
			self.uboot_fit_vma = hex_norm(args.uboot_fit_vma or uboot_fit_arr[0])
			self.uboot_load_address = hex_norm(board_cfg.get("uboot_load_address", "0x44100000"))
		else:
			# The TF-A FIP VMA for RZ boards comes from TOML unless overridden.
			fip_arr = method_cfg.get("FIP", [])
			if args.fip_vma:
				self.fip_vma = hex_norm(args.fip_vma)
			elif self.method == "xspi":
				self.fip_vma = hex_norm(fip_arr[0])
			elif self.method == "emmc":
				self.fip_vma = hex_norm(fip_arr[2])

		# FIP align & tb-kind
		self.fip_align  = int(args.fip_align) if args.fip_align else 16
		self.fip_tb_kind = (args.fip_tb_kind or "soc").lower()
		if self.fip_tb_kind not in ("soc", "tb"):
			raise ValueError("fip_tb_kind must be 'soc' or 'tb'")

		# Outputs
		self.spl_bp        = self.out_dir / f"spl_bp_{self.board}.bin"
		self.spl_bp_srec   = self.out_dir / f"spl_bp_{self.board}.srec"
		self.bl2_bp        = self.out_dir / f"bl2_bp_{self.board}.bin"
		self.bl2_bp_esd    = self.out_dir / f"bl2_bp_esd_{self.board}.bin"
		self.bl2_bp_srec   = self.out_dir / f"bl2_bp_{self.board}.srec"
		self.uboot_withdtb = self.out_dir / f"u-boot_{self.board}.bin"
		self.uboot_fit      = self.out_dir / f"u-boot_{self.board}.itb"
		self.uboot_fit_srec = self.out_dir / f"u-boot_{self.board}.srec"
		self.fip_bin       = self.out_dir / f"fip_{self.board}.bin"
		self.fip_srec      = self.out_dir / f"fip_{self.board}.srec"
		self.bl2_padded   = self.out_dir / f"bl2_padded_{self.board}.bin"  # BL2 + padding
		self.bl2_withdtb  = self.out_dir / f"bl2_{self.board}.bin"         # BL2 + padding + DTB(s)
		self.bl2_out = self.bl2_withdtb

		# Soft warnings
		if self.soc == "v4h":
			for p, name in [(self.sa0_bin, "SA0+SPL"), (self.ubnd, "U-BOOT-NODTB")]:
				if not p.exists():
					print(f"[warn] {name} not found at: {p}")
			if not any(p.exists() for p in self.uboot_dtbs):
				print(f"[warn] U-Boot DTBs not found at: {self.uboot_dtbs}")
		else:
			for p, name in [(self.bl2,"BL2"),(self.bl31,"BL31"),(self.ubnd,"U-BOOT-NODTB")]:
				if not p.exists():
					print(f"[warn] {name} not found at: {p}")
			if not any(p.exists() for p in self.atf_fdts):
				print(f"[warn] ATF FDTs not found at: {self.atf_fdts}")
			if not any(p.exists() for p in self.uboot_dtbs):
				print(f"[warn] U-Boot DTBs not found at: {self.uboot_dtbs}")

	def load_json(self):
		try:
			with open(self.json_file, 'r') as f:
				self.boards_data = json.load(f)
		except FileNotFoundError:
			print(f"File '{self.json_file}' not found.")
		except json.JSONDecodeError as e:
			print(f"Error decoding JSON: {e}")

	def make_bl2_padded(self):
		"""Pads the BL2 binary with null bytes to reach the DTB limit."""
		if not self.bl2.exists():
			print(f"ERROR: BL2 file not found at {self.bl2}")
			print(f"Please ensure the BL2 binary is available before running this script.")
			sys.exit(1)

		bl2_size = self.bl2.stat().st_size
		padding = self.bl2_padded_limit - bl2_size

		if padding < 0:
			print(f"Error: BL2 size ({bl2_size} bytes) exceeds the padding limit ({self.bl2_padded_limit} bytes).")
			sys.exit(1)

		print(f"[build] Padding BL2 from {bl2_size} to {self.bl2_padded_limit} bytes...")

		try:
			shutil.copyfile(self.bl2, self.bl2_padded)
			with open(self.bl2_padded, 'ab') as f_out:
				f_out.write(b'\x00' * padding)
			print(f"INFO: Padded file created at {self.bl2_padded}")
		except Exception as e:
			raise RuntimeError(f"Failed to pad BL2 file: {e}")

	def step_bl2_plus_fdts(self):
		# Create the padded BL2 file
		self.make_bl2_padded()

		# Concatenate the padded BL2 + board DTB
		fdts = [p for p in self.atf_fdts if p.exists()]
		if not self.bl2_padded.exists():
			raise FileNotFoundError(f"Padded BL2 image missing: {self.bl2_padded}")
		if not fdts:
			raise FileNotFoundError(f"ATF FDTs missing (checked: {self.atf_fdts})")

		print(f"[build] Concatenating padded BL2 and ATF FDTs -> {self.bl2_withdtb.name}")
		cat_files(self.bl2_withdtb, self.bl2_padded, *fdts)

	def step_bootparameter_and_srec(self):
		"""Generate boot parameter, append BL2+ATF-FDTs, and convert to SREC."""
		print(f"[build] bootparameter -> {self.bl2_bp.name}")
		bp_cmd = [str(self.tools.bootparameter), "--soc", self.bpgen_soc,
				"--image", str(self.bl2_out), "-o", str(self.bl2_bp)]
		if self.bpgen_soc == "v2h":
			bp_cmd += ["--mode", self.method, "--dest", self.bl2_dest]

		subprocess.check_call(bp_cmd)
		shutil.copy2(self.bl2_bp, self.bl2_bp_esd)
		with open(self.bl2_bp, "ab") as out_f, open(self.bl2_out, "rb") as in_f:
			shutil.copyfileobj(in_f, out_f)
		if self.method == "esd":
			print("[build] skipping BL2 boot parameter SREC for eSD method")
			return

		print(f"[build] objcopy -> {self.bl2_bp_srec.name} (VMA {self.bl2_bp_vma})")
		subprocess.check_call([str(self.tools.objcopy),
							"-I","binary","-O","srec",
							f"--adjust-vma={self.bl2_bp_vma}","--srec-forceS3",
							str(self.bl2_bp), str(self.bl2_bp_srec)])

	def step_uboot_with_dtbs(self):
		"""Concatenate u-boot-nodtb with U-Boot DTBs into u-boot_<board>.bin."""
		print(f"[build] U-Boot(nodtb)+DTBs -> {self.uboot_withdtb.name}")
		dtbs = [p for p in self.uboot_dtbs if p.exists()]
		if not self.ubnd.exists():
			raise FileNotFoundError(f"u-boot-nodtb missing: {self.ubnd}")
		if not dtbs:
			raise FileNotFoundError(f"U-Boot DTBs missing (checked: {self.uboot_dtbs})")
		cat_files(self.uboot_withdtb, self.ubnd, *dtbs)

	def step_fip_and_srec(self):
		"""Generate FIP image (BL31+U-Boot[+OP-TEE]), then convert to SREC with VMA."""
		print(f"[build] FIP -> {self.fip_bin.name}")
		if not self.bl31.exists():
			raise FileNotFoundError(f"BL31 missing: {self.bl31}")
		cmd = [str(self.tools.fiptool), "create", "--align", str(self.fip_align)]
		if self.fip_tb_kind == "tb":
			cmd += ["--tb-fw", str(self.bl31)]
		else:
			cmd += ["--soc-fw", str(self.bl31)]
		tee_name = self.boards_data[self.board].get("tee")
		tee_bin = IMG_DIR / "atf" / tee_name if tee_name else None
		if tee_bin and tee_bin.exists():
			print(f"[build] OP-TEE BL32 -> {tee_bin.name} included in FIP")
			cmd += ["--tos-fw", str(tee_bin)]
		elif tee_name:
			print(f"[warn] tee binary not found at {tee_bin}, skipping --tos-fw")
		cmd += ["--nt-fw", str(self.uboot_withdtb), str(self.fip_bin)]
		subprocess.check_call(cmd)
		if self.method == "esd":
			print("[build] skipping FIP SREC for eSD method")
			return

		print(f"[build] objcopy -> {self.fip_srec.name} (VMA {self.fip_vma})")
		subprocess.check_call([str(self.tools.objcopy),
							"-I","binary","-O","srec",
							f"--adjust-vma={self.fip_vma}","--srec-forceS3",
							str(self.fip_bin), str(self.fip_srec)])

	def step_sa0_and_srec(self):
		"""V4H: copy the pre-built SA0 header + SPL blob (sa0.bin) as spl_bp, then SREC."""
		if not self.sa0_bin.exists():
			raise FileNotFoundError(f"SA0+SPL blob missing: {self.sa0_bin}")
		print(f"[build] SA0+SPL -> {self.spl_bp.name}")
		shutil.copy2(self.sa0_bin, self.spl_bp)

		print(f"[build] objcopy -> {self.spl_bp_srec.name} (VMA {self.spl_bp_vma})")
		subprocess.check_call([str(self.tools.objcopy),
							"-I","binary","-O","srec",
							f"--adjust-vma={self.spl_bp_vma}","--srec-forceS3",
							str(self.spl_bp), str(self.spl_bp_srec)])

	def step_uboot_fit_and_srec(self):
		"""V4H: package U-Boot nodtb with the selected board DTB into a FIT."""
		if not self.ubnd.exists():
			raise FileNotFoundError(f"u-boot-nodtb missing: {self.ubnd}")
		dtbs = [p for p in self.uboot_dtbs if p.exists()]
		if len(dtbs) != 1:
			raise ValueError(
				f"V4H requires exactly one U-Boot DTB; found {len(dtbs)} from {self.uboot_dtbs}"
			)

		print(f"[build] U-Boot FIT -> {self.uboot_fit.name}")
		cmd = [
			str(self.tools.mkimage),
			"-f", "auto",
			"-A", "arm64",
			"-T", "firmware",
			"-C", "none",
			"-O", "u-boot",
			"-a", self.uboot_load_address,
			"-e", self.uboot_load_address,
			"-n", f"U-Boot FIT for {self.board}",
		]
		cmd += ["-b", str(dtbs[0])]
		cmd += ["-d", str(self.ubnd), str(self.uboot_fit)]
		subprocess.check_call(cmd)

		print(f"[build] objcopy -> {self.uboot_fit_srec.name} (VMA {self.uboot_fit_vma})")
		subprocess.check_call([str(self.tools.objcopy),
								"-I","binary","-O","srec",
								f"--adjust-vma={self.uboot_fit_vma}","--srec-forceS3",
								str(self.uboot_fit), str(self.uboot_fit_srec)])

	def run_all_v4h(self):
		"""V4H build pipeline: SA0+SPL plus a board-specific U-Boot FIT."""
		self.step_sa0_and_srec()
		self.step_uboot_fit_and_srec()
		print("\n=== Artifacts ===")
		for k, v in {
			"spl_bp": self.spl_bp,
			"spl_bp_srec": self.spl_bp_srec,
			"uboot_fit": self.uboot_fit,
			"uboot_fit_srec": self.uboot_fit_srec,
		}.items():
			print(f"{k:12s} -> {v}")

	def run_all(self):
		"""Run the full build pipeline sequentially."""
		self.step_bl2_plus_fdts()
		self.step_bootparameter_and_srec()
		self.step_uboot_with_dtbs()
		self.step_fip_and_srec()
		print("\n=== Artifacts ===")
		artifacts = {
			"bl2_output": self.bl2_out,
			"bl2_bp": self.bl2_bp,
			"bl2_bp_esd": self.bl2_bp_esd,
			"u_boot": self.uboot_withdtb,
			"fip_bin": self.fip_bin,
		}
		if self.method != "esd":
			artifacts["bl2_bp_srec"] = self.bl2_bp_srec
			artifacts["fip_srec"] = self.fip_srec
		for k, v in artifacts.items():
			print(f"{k:12s} -> {v}")

# ---------- CLI ----------
def parse_args(argv=None) -> argparse.Namespace:
	"""Parse command-line arguments for firmware_build.py."""
	p = argparse.ArgumentParser(description="Build board-specific RZ bootloader artifacts.")
	p.add_argument("--board", default="rzg2l-sbc")
	p.add_argument("--soc", choices=["g2l", "v2l", "v2h", "v4h"],
				help="Target SoC family")
	p.add_argument("--method", choices=['emmc', 'xspi', 'esd'],
				help="Which flash method's VMA rules to use (default: xspi)")

	p.add_argument("--bl2")
	p.add_argument("--atf-fdts", nargs="+", help="ATF FDT(s) to append to BL2 for bl2_<board>.bin")
	p.add_argument("--uboot-dtbs", nargs="+", help="U-Boot DTB(s) to append to u-boot-nodtb")
	p.add_argument("--bl31")
	p.add_argument("--u-boot-nodtb")
	p.add_argument("--spl", "--sa0-bin", dest="sa0_bin",
				help="V4H: pre-built SA0 header + SPL blob (sa0.bin). "
					"--spl is the canonical name; --sa0-bin is kept as a compatibility alias.")
	p.add_argument("--out-dir", default=f"{IMG_DIR}")

	# tools
	p.add_argument("--bootparameter")
	p.add_argument("--fiptool")
	p.add_argument("--mkimage", help="V4H: U-Boot mkimage executable")
	p.add_argument("--objcopy")

	# overrides (optional)
	p.add_argument("--fip-align")
	p.add_argument("--fip-vma")
	p.add_argument("--uboot-fit-vma", help="V4H: override U-Boot FIT SREC VMA")
	p.add_argument("--bl2-bp-vma")
	p.add_argument("--spl-bp-vma", help="V4H: override SPL BP VMA")
	p.add_argument("--fip-tb-kind", choices=["soc","tb"])

	return p.parse_args(argv)

def main(argv=None):
	"""Entrypoint: parse args, build firmware pipeline."""
	args = parse_args(argv)
	builder = FirmwareBuilder(args)
	if builder.soc == "v4h":
		builder.run_all_v4h()
	else:
		builder.run_all()

if __name__ == "__main__":
	main()
