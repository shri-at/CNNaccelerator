set_db use_scan_seqs_for_non_dft false
# to avoid using scan flip flops
set_db init_lib_search_path /home/cadence/install/FOUNDRY/digital/90nm/dig/lib/
set_db init_hdl_search_path /PathOfVerilogFile
read_libs typical.lib
read_hdl ./RTL.v
elaborate
read_sdc ./con.sdc
set_db syn_generic_effort medium
set_db syn_map_effort medium
set_db syn_opt_effort medium

syn_generic
syn_map
syn_opt

write_hdl >> netlist.v
write_sdc >> netlist.sdc