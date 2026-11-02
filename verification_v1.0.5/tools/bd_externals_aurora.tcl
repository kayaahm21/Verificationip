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

# =====================================================================
# IUB (Aurora 8b10b VIP) icin dis portlar. Kullanim:
#   make_iub_externals aurora_8b10b_vip_0
# Port adlari Aurora_wrapper'daki IUB_* adlariyla ayni olur. DRP portu yoktur.
# =====================================================================
proc make_iub_externals {cell} {
    foreach n {CORE_CONTROL CORE_STATUS GT_SERIAL_RX GT_SERIAL_TX} {
        set q [get_bd_intf_ports -quiet IUB_$n]
        if {$q ne ""} { delete_bd_objs $q; puts "silindi: IUB_$n" }
    }
    set map [list \
        loopback         IUB_CORE_CONTROL_loopback \
        pll_not_locked   IUB_CORE_CONTROL_pll_not_locked \
        power_down       IUB_CORE_CONTROL_power_down \
        bufg_gt_clr_out  IUB_CORE_STATUS_bufg_gt_clr_out \
        channel_up       IUB_CORE_STATUS_channel_up \
        crc_pass_fail_n  IUB_CORE_STATUS_crc_pass_fail \
        crc_valid        IUB_CORE_STATUS_crc_valid \
        frame_err        IUB_CORE_STATUS_frame_err \
        hard_err         IUB_CORE_STATUS_hard_err \
        lane_up          IUB_CORE_STATUS_lane_up \
        rx_resetdone_out IUB_CORE_STATUS_rx_resetdone_out \
        soft_err         IUB_CORE_STATUS_soft_err \
        tx_lock          IUB_CORE_STATUS_tx_lock \
        tx_resetdone_out IUB_CORE_STATUS_tx_resetdone_out \
        rxn              IUB_GT_SERIAL_RX_rxn \
        rxp              IUB_GT_SERIAL_RX_rxp \
        txn              IUB_GT_SERIAL_TX_txn \
        txp              IUB_GT_SERIAL_TX_txp \
        gt_powergood     iub_gt_powergood ]
    foreach {pin ext} $map {
        set p [get_bd_pins -quiet $cell/$pin]
        if {$p eq ""} { puts "UYARI: $cell/$pin bulunamadi"; continue }
        make_bd_pins_external -name $ext $p
        puts "$cell/$pin -> $ext"
    }
}
