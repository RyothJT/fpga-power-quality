import os
import sys
import argparse
import subprocess
import glob
import shutil
from pathlib import Path
from datetime import datetime

# Configuration & Paths
PROJECT_DIR = Path(__file__).resolve().parent
SIM_DIR = PROJECT_DIR / "sim"
SRC_DIR = PROJECT_DIR / "src"
GEN_DIR = SIM_DIR / "gen"
VCD_DIR = GEN_DIR / "vcd"
MAX_WAVES = 5


def cleanup_backups(tb_module: str):
    """Retains only the newest MAX_WAVES - 1 backups."""
    pattern = str(VCD_DIR / f"{tb_module}_*.vcd")
    backups = sorted(glob.glob(pattern), key=os.path.getmtime)
    if len(backups) >= MAX_WAVES:
        for f in backups[: len(backups) - (MAX_WAVES - 1)]:
            os.remove(f)


def find_tb_file(tb_name: str) -> Path:
    """Locates the testbench file recursively under sim/."""
    tb_clean = Path(tb_name).stem
    matches = list(SIM_DIR.rglob(f"{tb_clean}.v")) + list(SIM_DIR.rglob(f"{tb_clean}.sv"))
    if not matches:
        print(f"Error: Could not find testbench '{tb_clean}' in {SIM_DIR}")
        sys.exit(1)
    return matches[0]


def collect_hdl_sources():
    """Recursively collects all synthesizable Verilog/SystemVerilog files."""
    sources = []
    for ext in ("*.v", "*.sv"):
        sources.extend(SRC_DIR.rglob(ext))
    return [str(s) for s in sources]


def run_iverilog(tb_file: Path, tb_module: str, current_vcd: Path):
    """Lightweight Icarus compilation for pure Verilog modules."""
    vvp_dir = GEN_DIR / "vvp"
    vvp_dir.mkdir(parents=True, exist_ok=True)
    vvp_out = vvp_dir / f"{tb_module}.vvp"

    sources = collect_hdl_sources() + [str(tb_file)]
    cmd_compile = [
        "iverilog",
        "-g2012",
        "-Wall",
        f'-DDUMP_FILE="{current_vcd}"',
        "-s", tb_module,
        "-o", str(vvp_out),
    ] + sources

    print(f"--- [Icarus] Compiling: {tb_module} ---")
    if subprocess.run(cmd_compile).returncode != 0:
        print("Compilation failed!")
        sys.exit(1)

    print("--- [Icarus] Running Simulation ---")
    subprocess.run(["vvp", "-n", str(vvp_out)], check=True)


def run_vivado_xsim(tb_file: Path, tb_module: str, current_vcd: Path):
    """Full Xilinx Vivado simulation toolchain (xvhdl/xvlog -> xelab -> xsim -> vcd)."""
    work_dir = GEN_DIR / "xsim_work" / tb_module
    work_dir.mkdir(parents=True, exist_ok=True)
    os.chdir(work_dir)

    sources = collect_hdl_sources() + [str(tb_file)]
    
    # 1. Parse Verilog Sources
    print(f"--- [Vivado] Parsing Sources for {tb_module} ---")
    xvlog_cmd = ["xvlog", "--sv"] + sources
    subprocess.run(xvlog_cmd, check=True)

    # 2. Elaborate Design
    print(f"--- [Vivado] Elaborating Design: {tb_module} ---")
    xelab_cmd = ["xelab", tb_module, "-s", f"{tb_module}_sim", "--debug", "typical"]
    subprocess.run(xelab_cmd, check=True)

    # 3. Generate Tcl script for WDB to VCD dump
    tcl_script = work_dir / "dump.tcl"
    tcl_script.write_text(
        f"open_wave_database {tb_module}_sim.wdb\n"
        f"export_aside_vcd -file {current_vcd}\n"
        "exit\n"
    )

    # 4. Run Simulation
    print(f"--- [Vivado] Executing Simulation ---")
    xsim_cmd = ["xsim", f"{tb_module}_sim", "-R"]
    subprocess.run(xsim_cmd, check=True)

    # Convert to VCD if xsim generated a .wdb file
    wdb_file = work_dir / f"{tb_module}_sim.wdb"
    if wdb_file.exists():
        subprocess.run(["xsim", f"{tb_module}_sim", "-tclbatch", str(tcl_script)], check=True)

    os.chdir(PROJECT_DIR)


def launch_surfer(current_vcd: Path, backup_vcd: Path):
    """Backs up VCD and opens/notifies Surfer waveform viewer."""
    if not current_vcd.exists():
        print(f"Error: VCD output not found at {current_vcd}")
        sys.exit(1)

    shutil.copy(current_vcd, backup_vcd)
    print(f"Saved waveform backup: {backup_vcd}")

    # Check if surfer is running
    pgrep = subprocess.run(["pgrep", "-x", "surfer"], capture_output=True)
    if pgrep.returncode == 0:
        print("Surfer is already open. Please reload/refresh 'current.vcd' in the UI.")
    else:
        print("Launching Surfer...")
        surfer_bin = os.path.expanduser("~/.cargo/bin/surfer")
        surfer_cmd = surfer_bin if os.path.exists(surfer_bin) else "surfer"
        subprocess.Popen([surfer_cmd, str(current_vcd)])


def main():
    parser = argparse.ArgumentParser(description="Run simulation and view waveforms in Surfer.")
    parser.add_argument("testbench", help="Name or path of the testbench (e.g., tb_dds_top)")
    parser.add_argument("--tool", choices=["iverilog", "xsim"], default="iverilog",
                        help="Simulation tool engine (default: iverilog)")
    args = parser.parse_args()

    tb_file = find_tb_file(args.testbench)
    tb_module = tb_file.stem

    VCD_DIR.mkdir(parents=True, exist_ok=True)
    current_vcd = VCD_DIR / "current.vcd"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_vcd = VCD_DIR / f"{tb_module}_{timestamp}.vcd"

    cleanup_backups(tb_module)

    if args.tool == "xsim":
        run_vivado_xsim(tb_file, tb_module, current_vcd)
    else:
        run_iverilog(tb_file, tb_module, current_vcd)

    launch_surfer(current_vcd, backup_vcd)


if __name__ == "__main__":
    main()
