# # gen_xadc.tcl
# set ip_name "xadc_wiz_0"
# set ip_dir "./src/ip"

# if { [get_ips -quiet $ip_name] eq "" } {
#     create_ip -name xadc_wiz -vendor xilinx.com -library ip -version 3.3 \
#               -module_name $ip_name -dir $ip_dir
# }
# set xadc_ip [get_ips $ip_name]

# # 1. Enable Sequencer and DRP
# set_property -dict [list \
#     CONFIG.INTERFACE_SELECTION {Enable_DRP} \
#     CONFIG.STARTUP_CHANNEL_SELECTION {Channel_Sequencer} \
# ] $xadc_ip

# # 2. Configure for Simultaneous Sampling (VAUX6 and VAUX14)
# set_property -dict [list \
#     CONFIG.SEQUENCER_MODE {Simultaneous_Selection} \
#     CONFIG.ADC_CONVERSION_RATE {100} \
#     CONFIG.DCLK_FREQUENCY {100} \
#     CONFIG.CHANNEL_ENABLE_VAUXP6_VAUXN6 {true} \
#     CONFIG.CHANNEL_ENABLE_VAUXP14_VAUXN14 {true} \
#     CONFIG.EXTERNAL_MUX_CHANNEL {VAUXP6_VAUXN6} \
# ] $xadc_ip

# # 3. Global Synthesis
# set xci_file [get_files -all -filter "NAME =~ */$ip_name.xci"]
# set_property GENERATE_SYNTH_CHECKPOINT 0 [get_files $xci_file]

# generate_target all $xadc_ip
