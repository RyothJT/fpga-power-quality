import os
import sys
import subprocess
import argparse

def main():
    # 1. Setup Argument Parser
    parser = argparse.ArgumentParser(description="Remote FPGA Build and Flash Utility")
    parser.add_argument("remote", help="Remote SSH host (e.g., vlsi or user@host)")
    parser.add_argument("--flash", type=int, default=1, choices=[0, 1], help="Flash board on remote (1=Yes, 0=No)")
    args = parser.parse_args()

    # 2. Configuration
    proj_root = os.path.dirname(os.path.abspath(__file__))
    remote_path = "~/projects/fpga-power-quality/"
    
    # Path to Vivado settings on the REMOTE machine
    REMOTE_VIVADO_SETTINGS = "/tools/Xilinx/2025.2/Vivado/settings64.sh"

    # -------------------------------------------------------------------------
    # [1/3] Sync Source to Remote
    # -------------------------------------------------------------------------
    print(f"\n[1/3] Syncing source to {args.remote}...")
    rsync_cmd = [
        "rsync", "-avz", "--delete",
        "--exclude", ".git/",
        "--exclude", "sim/gen/",
        "--exclude", "syn/gen/",
        f"{proj_root}/", 
        f"{args.remote}:{remote_path}"
    ]
    
    try:
        subprocess.check_call(rsync_cmd)
    except subprocess.CalledProcessError:
        print("Error: Rsync failed.")
        sys.exit(1)

    # -------------------------------------------------------------------------
    # [2/3] Run Synthesis and Implementation on Remote
    # -------------------------------------------------------------------------
    print(f"\n[2/3] Starting remote build on {args.remote}...")
    remote_build_cmd = (
        f"source {REMOTE_VIVADO_SETTINGS} && "
        f"cd {remote_path} && "
        "vivado -mode batch "
        "-source syn/tcl/build_bitstream.tcl "
        "-log syn/logs/build.log "
        "-journal syn/logs/build.jou"
    )
    
    # Use bash -l to ensure login shell environment
    ssh_build_cmd = ["ssh", args.remote, f"bash -l -c '{remote_build_cmd}'"]
    
    try:
        subprocess.check_call(ssh_build_cmd)
    except subprocess.CalledProcessError:
        print("\nError: Remote build failed. Check syn/logs/build.log on remote.")
        sys.exit(1)

    # -------------------------------------------------------------------------
    # [3/3] Flash Board on Remote
    # -------------------------------------------------------------------------
    if args.flash == 1:
        print(f"\n[3/3] Build successful. Flashing Basys 3 on {args.remote}...")
        
        remote_flash_cmd = (
            f"source {REMOTE_VIVADO_SETTINGS} && "
            f"cd {remote_path} && "
            "vivado -mode batch -source syn/tcl/program_basys3.tcl"
        )
        
        ssh_flash_cmd = ["ssh", args.remote, f"bash -l -c '{remote_flash_cmd}'"]
        
        try:
            subprocess.check_call(ssh_flash_cmd)
            print("\nSuccess: Remote board programmed.")
        except subprocess.CalledProcessError:
            print("\nError: Remote flash failed. Is the Basys 3 plugged into the remote machine?")
            sys.exit(1)
    else:
        print("\n[3/3] Skipping flash as requested.")

if __name__ == "__main__":
    main()
