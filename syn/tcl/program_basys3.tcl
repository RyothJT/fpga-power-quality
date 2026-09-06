# 1. Connect to the local end of the SSH tunnel
open_hw_manager
connect_hw_server -url localhost:3121

# 2. Find and open the Digilent JTAG target
current_hw_target [get_hw_targets */xilinx_tcf/Digilent/*]
set_property PARAM.FREQUENCY 15000000 [get_hw_targets */xilinx_tcf/Digilent/*]
open_hw_target

# 3. Identify the Artix-7 35T device
set device [get_hw_devices xc7a35t_0]
current_hw_device $device
refresh_hw_device $device

# 4. Program the bitstream
set_property PROGRAM.FILE "./syn/gen/build_output/system_top.bit" $device
program_hw_devices $device

# 5. Done
close_hw_target
disconnect_hw_server
close_hw_manager
exit
