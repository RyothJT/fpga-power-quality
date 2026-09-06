import os
import sys
import subprocess
import argparse

def main():
    # 1. Setup Argument Parser
    parser = argparse.ArgumentParser(description="Remote FPGA Build and Flash Utility")
    parser.add_argument("remote", help="Remote SSH host (e.g., desktop or user@host)")
    parser.add_argument(
        "--flash", 
        choices=['fpga', 'spi', 'none'], 
        default='none', 
        help="Flash target: 'fpga' (JTAG/volatile), 'spi' (Flash/permanent), or 'none'"
    )
    args = parser.parse_args()

    # 2. Configuration
    proj_root = os.path.dirname(os.path.abspath(__file__))
    remote_path = "~/projects/fpga-power-quality" # No trailing slash for easier path building
    
    REMOTE_VIVADO_SETTINGS = "/tools/Xilinx/2025.2/Vivado/settings64.sh"

    # [1/3] Sync Source to Remote
    print(f"\n[1/3] Syncing source to {args.remote}...")
    rsync_cmd = [
        "rsync", "-avz", "--delete",
        "--exclude", ".git/", "--exclude", "sim/gen/", "--exclude", "syn/gen/",
        f"{proj_root}/", f"{args.remote}:{remote_path}/"
    ]
    
    try:
        subprocess.check_call(rsync_cmd)
    except subprocess.CalledProcessError:
        print("Error: Rsync failed.")
        sys.exit(1)

    # [2/3] Run Build on Remote
    print(f"\n[2/3] Starting remote build on {args.remote}...")
    remote_build_cmd = (
        f"source {REMOTE_VIVADO_SETTINGS} && "
        f"cd {remote_path} && "
        "vivado -mode batch -source syn/tcl/build_bitstream.tcl "
        "-log syn/logs/build.log -journal syn/logs/build.jou"
    )
    
    ssh_build_cmd = ["ssh", args.remote, f"bash -l -c '{remote_build_cmd}'"]
    
    try:
        subprocess.check_call(ssh_build_cmd)
    except subprocess.CalledProcessError:
        print("\nError: Remote build failed. Check syn/logs/build.log on remote.")
        sys.exit(1)

    # [3/3] Flash Board on Remote
    if args.flash != 'none':
        tcl_script = "program_spi_flash.tcl" if args.flash == 'spi' else "program_basys3.tcl"
        mode_str = "SPI Flash (Permanent)" if args.flash == 'spi' else "JTAG (Volatile)"
        
        print(f"\n[3/3] Build successful. Flashing via {mode_str} on {args.remote}...")
        
        # Pass the remote path as a variable to the Tcl script so it can use absolute paths
        remote_flash_cmd = (
            f"source {REMOTE_VIVADO_SETTINGS} && "
            f"cd {remote_path} && "
            f"vivado -mode batch -source syn/tcl/{tcl_script} -tclargs {remote_path}"
        )
        
        ssh_flash_cmd = ["ssh", args.remote, f"bash -l -c '{remote_flash_cmd}'"]
        
        try:
            subprocess.check_call(ssh_flash_cmd)
            print(f"\nSuccess: Remote board programmed via {mode_str}.")
        except subprocess.CalledProcessError:
            print(f"\nError: Remote flash failed. Is the Basys 3 plugged into {args.remote}?")
            sys.exit(1)
    else:
        print("\n[3/3] Build successful. Skipping flash as requested.")

if __name__ == "__main__":
    main()
