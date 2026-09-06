# Handle absolute project root
if { $argc > 0 } { set PROJ_ROOT [lindex $argv 0] } else { set PROJ_ROOT [pwd] }

set bit_file "$PROJ_ROOT/syn/gen/build_output/system_top.bit"
set mcs_file "$PROJ_ROOT/syn/gen/build_output/system_top.mcs"
set prm_file "$PROJ_ROOT/syn/gen/build_output/system_top.prm"

# 1. Generate MCS for Macronix (Safe 1-bit mode)
puts "--- Generating MCS for Macronix (SPIx1) ---"
write_cfgmem -format mcs -size 4 -interface SPIx1 -loadbit "up 0 $bit_file" -file $mcs_file -force

# 2. Setup Hardware Manager
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target

set current_device [lindex [get_hw_devices xc7a35t_0] 0]
current_hw_device $current_device

# --- MACRONIX PART SELECTION ---
# We use the exact ID found in your previous search for Vivado 2025.2
set flash_part "mx25l3273f-spi-x1_x2_x4"

# If that fails, we try a broader search as a backup
if { [get_cfgmem_parts -quiet $flash_part] == "" } {
    puts "Exact part $flash_part not found, searching for candidates..."
    set candidates [get_cfgmem_parts -filter {NAME =~ "mx25l32*" && IS_SUPPORTED}]
    if { [llength $candidates] > 0 } {
        set flash_part [lindex $candidates 0]
    } else {
        puts "ERROR: No MX25L Macronix parts found. Available parts:"
        puts [get_cfgmem_parts -filter {NAME =~ "mx*"}]
        exit 1
    }
}
puts "Final Selected Part: $flash_part"

# 3. Attach and Configure
if { [get_property PROGRAM.HW_CFGMEM $current_device] != "" } {
    delete_hw_cfgmem [get_property PROGRAM.HW_CFGMEM $current_device]
}

create_hw_cfgmem -hw_device $current_device [lindex [get_cfgmem_parts $flash_part] 0]
set cfg_mem [get_property PROGRAM.HW_CFGMEM $current_device]

# Set every relevant property
set_property PROGRAM.ADDRESS_RANGE            {entire_device} $cfg_mem
set_property PROGRAM.FILES                    [list $mcs_file] $cfg_mem
set_property PROGRAM.PRM_FILE                 [list $prm_file] $cfg_mem
set_property PROGRAM.UNUSED_PIN_TERMINATION   {pull-none}      $cfg_mem
set_property PROGRAM.BLANK_CHECK              0                $cfg_mem
set_property PROGRAM.ERASE                    1                $cfg_mem
set_property PROGRAM.CFG_PROGRAM              1                $cfg_mem
set_property PROGRAM.VERIFY                   1                $cfg_mem
set_property PROGRAM.CHECKSUM                 0                $cfg_mem

# 4. Start Programming
puts "--- Starting Macronix Flash Program ---"
create_hw_bitstream -hw_device $current_device -file $bit_file
program_hw_cfgmem -hw_cfgmem $cfg_mem

# 5. Finalize
boot_hw_device $current_device
puts "--- Success: Macronix SPI Flash Programmed ---"
exit
