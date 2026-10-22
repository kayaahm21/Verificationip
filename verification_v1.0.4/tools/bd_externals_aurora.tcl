# =====================================================================
# Aurora VIP hucresini BD'ye koyduktan sonra, Top.vhd'nin bekledigi dis portlari olusturur.
#
# Kullanim (BD acikken Tcl Console'da):
#   source <yol>/bd_externals_aurora.tcl
#   make_aurora_externals shob_1_aurora_gth SHOB_1
#   make_aurora_externals shob_2_aurora_gth SHOB_2
#
# Aurora'ya ozgu arayuzler (CORE_CONTROL/CORE_STATUS/GT_SERIAL) paketlenmedigi icin duz pinlerdir.
# Burada her pin icin Top.vhd'deki ada uygun duz dis port acilir: <ONEK>_CORE_STATUS_channel_up gibi.
# Eski (bos kalmis) arayuz dis portlari silinir.
# =====================================================================
proc make_aurora_externals {cell prefix} {
    # eski, bagli olmayan arayuz dis portlarini sil (varsa)
    foreach n {CORE_CONTROL CORE_STATUS GT_SERIAL_RX GT_SERIAL_TX} {
        set q [get_bd_intf_ports -quiet ${prefix}_$n]
        if {$q ne ""} { delete_bd_objs $q; puts "silindi: ${prefix}_$n" }
    }
    # {VIP pini  dis port adi}
    set map [list \
        gt_rxcdrovrden_in   ${prefix}_CORE_CONTROL_gt_rxcdrovrden_in \
        loopback            ${prefix}_CORE_CONTROL_loopback \
        power_down          ${prefix}_CORE_CONTROL_power_down \
        channel_up          ${prefix}_CORE_STATUS_channel_up \
        crc_pass_fail_n     ${prefix}_CORE_STATUS_crc_pass_fail \
        crc_valid           ${prefix}_CORE_STATUS_crc_valid \
        gt_pll_lock         ${prefix}_CORE_STATUS_gt_pll_lock \
        hard_err            ${prefix}_CORE_STATUS_hard_err \
        lane_up             ${prefix}_CORE_STATUS_lane_up \
        mmcm_not_locked_out ${prefix}_CORE_STATUS_pll_not_locked_out \
        soft_err            ${prefix}_CORE_STATUS_soft_err \
        rxn                 ${prefix}_GT_SERIAL_RX_rxn \
        rxp                 ${prefix}_GT_SERIAL_RX_rxp \
        txn                 ${prefix}_GT_SERIAL_TX_txn \
        txp                 ${prefix}_GT_SERIAL_TX_txp ]
    foreach {pin ext} $map {
        set p [get_bd_pins -quiet $cell/$pin]
        if {$p eq ""} { puts "UYARI: $cell/$pin bulunamadi"; continue }
        make_bd_pins_external -name $ext $p
        puts "$cell/$pin -> $ext"
    }
}
