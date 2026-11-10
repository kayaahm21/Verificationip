`timescale 1ns / 1ps

// =====================================================================
// aurora_64b66b_vip  (v1.0.7)  -  Aurora 64B/66B IP'sinin yerine konan GOZLEMCI (observer) VIP
//
// Hedef: sinyal isleme FPGA'sindaki Aurora_aurora_64b66b_0_0 IP'sinin (3 lane, 192-bit AXI-S,
// UFC acik, DUPLEX) portlariyla BIREBIR ayni portlara sahip olmak; Block Design'da (verif projesi)
// shob_1_aurora_gth / shob_2_aurora_gth hucrelerinin yerine "module reference" olarak konur.
//
// Bu surumde VIP YALNIZCA GOZLEMLER:
//   * Link modelini uretir: user_clk_out (125 MHz), resetler, gt_powergood, gt_pll_lock, channel_up, lane_up
//   * Tasarimin gonderdigi UFC mesajini (ufc_tx_req/ufc_tx_ms + s_axi_ufc_tx_*) kabul eder
//     ve HAM haliyle log dosyasina yazar. CEVAP URETMEZ (RX arayuzleri bostadir).
//   * Kullanici verisi (s_axi_tx_*) her zaman kabul edilir ve (alt 128 bit) log'a yazilir.
//
// Log dosyasi: aurora_obs_<UNIT_NAME>.txt   (zaman damgali, satir satir)
//
// Derleme: davranis varsayilan olarak acik. VIP_STUB tanimlanirsa yalnizca portlar + sabit atamalar
// (BD'nin modulu ayristirabilmesi icin sade govde) derlenir. (Verif projesi sentezlenmez; yine de dosya sentez ayristiricisina uygundur.)
//
// Arayuz gruplari (X_INTERFACE_INFO): USER_DATA_S_AXIS_TX, USER_DATA_M_AXIS_RX, UFC_S_AXIS_TX,
// UFC_M_AXIS_RX standart AXI-Stream olarak gruplanir. Aurora'ya ozgu arayuz VLNV'leri (core_control,
// core_status, gt_serial vb.) bilinmedigi icin bu portlar DUZ port olarak birakilmistir;
// BD'de baglantilar tek tek (ya da otomatik) yapilabilir.
// =====================================================================
// Davranis varsayilan olarak ACIKTIR (ekstra tanim gerekmez). Yalnizca ayristirma icin sade govde
// istenirse VIP_STUB tanimlanir. (Eski VIP_BEHAVIORAL tanimi da kabul edilir, etkisi yoktur.)
// v1.0.7: CIT cevabi. SHOB'a 0000E003 (len=0) istegi gelince 1 us sonra 0000E004 (len=184) cevabi,
// UFC RX uzerinden 48 adet 4 baytlik UFC mesaji olarak verilir. Diger mesaj ID'leri yok sayilir.
`ifndef VIP_STUB
  `ifndef VIP_BEHAVIORAL
    `define VIP_BEHAVIORAL
  `endif
`endif

module aurora_64b66b_vip #(
    parameter UNIT_NAME      = "shob_1",   // log dosyasi adi: aurora_obs_<UNIT_NAME>.txt
    parameter LOG_ENABLE     = 1,          // 0: log yazma
    parameter UFC_IN_PROGRESS_IDLE = 1,     // ufc_in_progress bosta seviyesi (active-low ise 1)
    parameter LINK_UP_CLKS   = 625,        // reset'ten sonra channel_up'a kadar gecen user_clk sayisi (~5 us)
    // ---- v1.0.7: cevap uretimi ----
    parameter RESP_ENABLE      = 1,        // 0: cevap uretme (yalnizca gozlemci)
    parameter RESP_DELAY_CLKS  = 125,      // istekten ilk cevap kelimesine bekleme (125 clk = 1 us)
    parameter RESP_GAP_CLKS    = 1,        // cevap kelimeleri arasi bos clock sayisi
    parameter FIELD_BIG_ENDIAN = 0,        // cevaptaki uint16/uint32 alanlari: 0 = little-endian
    parameter WORD_BIG_ENDIAN  = 0,        // 4 baytlik kelime paketleme: 0 = ilk bayt tdata[7:0]
    parameter UPTIME_OFFSET_S  = 273600,   // cihaz saati baslangici (saniye); + simulasyon suresi
    // ---- v1.0.7: kullanici verisi (HUZPAR ve KATSAYILAR, ID 0000E001) gozlemi ----
    parameter MAX_MSG_BYTES    = 262144,   // en buyuk mesaj (ID+LEN+veri) bayt sayisi (HO, M=96 icin 184384)
    parameter LOG_RAW_BEATS    = 1,        // 1: her beat icin USER_TX satiri yaz (buyuk mesajlarda 0 yapilabilir)
    parameter LOG_DATA_BYTES   = 64,       // obs'taki MSG satirina yazilan en fazla veri bayti
    // ---- v1.0.7: huzme verisi (ID 00000002, SHOB -> SIFPGA) gonderimi, m_axi_rx_* uzerinden (192 bit) ----
    parameter DATA_ENABLE      = 1,        // 0: huzme verisi gonderme (v1.0.5 davranisi)
    parameter DATA_DELAY_CLKS  = 625,      // HUZPAR (0000E001) alindiktan sonra veri gonderiminin baslamasina kadar bekleme (625 clk = 5 us)
    parameter DATA_MUL         = 0,        // desen carpani: 0 = UNIT_NAME'den (shob_2 -> 2, digerleri 1), >0 elle
    parameter DATA_MAX_BYTES   = 33554432  // bundan buyuk mesaj gonderilmez (ornegin Bypass M=960 ve cok buyuk N)
)(
    // ---- TX AXI4-S (USER_DATA_S_AXIS_TX) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TDATA" *)  input  wire [191:0] s_axi_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TLAST" *)  input  wire         s_axi_tx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TKEEP" *)  input  wire [23:0]  s_axi_tx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TVALID" *) input  wire         s_axi_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_S_AXIS_TX TREADY" *) output wire         s_axi_tx_tready,

    // ---- RX AXI4-S (USER_DATA_M_AXIS_RX), tready yok ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TDATA" *)  output wire [191:0] m_axi_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TLAST" *)  output wire         m_axi_rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TKEEP" *)  output wire [23:0]  m_axi_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 USER_DATA_M_AXIS_RX TVALID" *) output wire         m_axi_rx_tvalid,

    // ---- UFC TX (UFC_S_AXIS_TX): tkeep/tlast yok ----
    input  wire         ufc_tx_req,
    input  wire [7:0]   ufc_tx_ms,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TDATA" *)  input  wire [191:0] s_axi_ufc_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TVALID" *) input  wire         s_axi_ufc_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_S_AXIS_TX TREADY" *) output wire         s_axi_ufc_tx_tready,

    // ---- UFC RX (UFC_M_AXIS_RX), tready yok ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TDATA" *)  output wire [191:0] m_axi_ufc_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TKEEP" *)  output wire [23:0]  m_axi_ufc_rx_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TLAST" *)  output wire         m_axi_ufc_rx_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 UFC_M_AXIS_RX TVALID" *) output wire         m_axi_ufc_rx_tvalid,
    output wire         ufc_in_progress,

    // ---- GT seri I/O ----
    input  wire [0:2]   rxp,
    input  wire [0:2]   rxn,
    output wire [0:2]   txp,
    output wire [0:2]   txn,

    // ---- GT referans saati ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 GT_DIFF_REFCLK1 CLK_P",
       X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input  wire         gt_refclk1_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 GT_DIFF_REFCLK1 CLK_N" *)
    input  wire         gt_refclk1_n,
    output wire         gt_refclk1_out,

    // ---- Hata / durum ----
    output wire         hard_err,
    output wire         soft_err,
    output wire         channel_up,
    output wire [0:2]   lane_up,
    output wire         crc_pass_fail_n,
    output wire         crc_valid,

    // ---- Sistem arayuzu ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 user_clk_out CLK",
       X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF USER_DATA_S_AXIS_TX:USER_DATA_M_AXIS_RX:UFC_S_AXIS_TX:UFC_M_AXIS_RX, FREQ_HZ 125000000" *)
    output wire         user_clk_out,
    output wire         mmcm_not_locked_out,
    output wire         sync_clk_out,
    input  wire         reset_pb,
    input  wire         gt_rxcdrovrden_in,
    input  wire         power_down,
    input  wire [2:0]   loopback,
    input  wire         pma_init,
    output wire         gt_pll_lock,

    input  wire         init_clk,
    output wire         link_reset_out,
    output wire [2:0]   gt_powergood,
    output wire         sys_reset_out,
    output wire         gt_reset_out,
    output wire         tx_out_clk
);

`ifdef VIP_BEHAVIORAL
    // =================================================================
    // DAVRANIS (yalnizca simulasyon)
    // =================================================================

    // ---- 125 MHz kullanici saati ----
    reg clk = 1'b0;
    always #4 clk = ~clk;                     // 8 ns periyot
    assign user_clk_out = clk;
    assign sync_clk_out = clk;
    assign tx_out_clk   = clk;
    assign gt_refclk1_out = gt_refclk1_p;     // referans saati dogrudan gecer

    // ---- Link modeli ----
    // ok=1 iken sayac ilerler; reset_pb / pma_init / power_down sayaci sifirlar (link yeniden kurulur).
    // Sira: gt_powergood -> gt_pll_lock -> gt_reset_out biter -> sys_reset_out biter -> channel_up/lane_up
    integer cnt = 0;
    wire    ok  = !(reset_pb === 1'b1 || pma_init === 1'b1 || power_down === 1'b1);
    always @(posedge clk) begin
        if (!ok) cnt <= 0;
        else if (cnt < 1000000) cnt <= cnt + 1;
    end

    assign gt_powergood        = (cnt >= 5)  ? 3'b111 : 3'b000;
    assign gt_pll_lock         = (cnt >= 8);
    assign gt_reset_out        = (cnt < 10);                     // aktif yuksek
    assign sys_reset_out       = (cnt < 20);                     // aktif yuksek
    assign mmcm_not_locked_out = (cnt < 4);
    assign channel_up          = (cnt >= LINK_UP_CLKS);
    assign lane_up             = (cnt >= LINK_UP_CLKS) ? 3'b111 : 3'b000;
    assign link_reset_out      = ~channel_up;
    assign hard_err            = 1'b0;
    assign soft_err            = 1'b0;
    assign crc_pass_fail_n     = 1'b1;
    assign crc_valid           = 1'b0;
    assign txp                 = 3'b000;
    assign txn                 = 3'b111;

    // ---- Kullanici verisi RX tarafi bos; UFC RX yalnizca CIT cevabi icin kullanilir ----
    // v1.0.7: huzme verisi gondericisi (asagida) bu register'lari surer
    reg [191:0] rx_tdata_r  = 192'd0;
    reg [23:0]  rx_tkeep_r  = 24'd0;
    reg         rx_tlast_r  = 1'b0;
    reg         rx_tvalid_r = 1'b0;
    assign m_axi_rx_tdata      = rx_tdata_r;
    assign m_axi_rx_tkeep      = rx_tkeep_r;
    assign m_axi_rx_tlast      = rx_tlast_r;
    assign m_axi_rx_tvalid     = rx_tvalid_r;
    // UFC RX cikislari cevap motoru tarafindan surulur (asagida)
    reg [191:0] ufc_rx_tdata_r  = 192'd0;
    reg [23:0]  ufc_rx_tkeep_r  = 24'd0;
    reg         ufc_rx_tlast_r  = 1'b0;
    reg         ufc_rx_tvalid_r = 1'b0;
    reg         ufc_ip_r        = UFC_IN_PROGRESS_IDLE[0];
    assign m_axi_ufc_rx_tdata  = ufc_rx_tdata_r;
    assign m_axi_ufc_rx_tkeep  = ufc_rx_tkeep_r;
    assign m_axi_ufc_rx_tlast  = ufc_rx_tlast_r;
    assign m_axi_ufc_rx_tvalid = ufc_rx_tvalid_r;
    assign ufc_in_progress     = ufc_ip_r;   // bosta seviyesi UFC_IN_PROGRESS_IDLE (active-low ise 1)

    // ---- Kullanici verisi: her zaman kabul ----
    assign s_axi_tx_tready = 1'b1;

    // ---- UFC TX el sikismasi ----
    // ufc_tx_req'in yukselen kenarinda istek alinir; mesaj boyutu (ufc_tx_ms+1) bayt,
    // 24 baytlik beat'lere bolunur (ms=3 -> 4 bayt -> 1 beat). Beat'ler bitene kadar tready=1.
    reg         req_d     = 1'b0;
    reg         busy      = 1'b0;
    integer     beats_left = 0;
    reg  [7:0]  ms_lat    = 8'd0;
    assign s_axi_ufc_tx_tready = busy;

    integer fd = 0;
    reg [8*64-1:0] fname;
    initial begin
        if (LOG_ENABLE != 0) begin
            $sformat(fname, "aurora_obs_%0s.txt", UNIT_NAME);
            fd = $fopen(fname, "w");
            $display("[AURORA %0s] DAVRANIS SURUMU aktif (v1.0.7). Log dosyasi: %0s", UNIT_NAME, fname);
            if (fd == 0) $display("[AURORA %0s] HATA: log dosyasi acilamadi", UNIT_NAME);
            else begin
                $fdisplay(fd, "# aurora_64b66b_vip gozlemci logu (birim=%0s). Zamanlar ns.", UNIT_NAME);
                $fflush(fd);
            end
        end
    end

    always @(posedge clk) begin
        req_d <= ufc_tx_req;

        // yeni UFC istegi
        if (ufc_tx_req && !req_d && !busy) begin
            busy       <= 1'b1;
            ms_lat     <= ufc_tx_ms;
            beats_left <= ((ufc_tx_ms + 1) + 23) / 24;
            if (fd != 0) begin
                $fdisplay(fd, "%0d UFC_REQ ms=%0d (%0d bayt)", $time, ufc_tx_ms, ufc_tx_ms + 1);
                $fflush(fd);
            end
        end

        // UFC verisi
        if (s_axi_ufc_tx_tvalid) begin
            if (busy) begin
                if (fd != 0) begin
                    $fdisplay(fd, "%0d UFC_TX tdata=%h", $time, s_axi_ufc_tx_tdata);
                    $fflush(fd);
                end
                if (beats_left <= 1) begin busy <= 1'b0; beats_left <= 0; end
                else                  beats_left <= beats_left - 1;
            end else if (fd != 0) begin
                $fdisplay(fd, "%0d UFC_TX_ISTEKSIZ tdata=%h (ufc_tx_req olmadan veri geldi, yok sayildi)",
                          $time, s_axi_ufc_tx_tdata);
                $fflush(fd);
            end
        end

        // kullanici verisi: yalnizca alt 128 bit anlamli
        if (s_axi_tx_tvalid && s_axi_tx_tready && fd != 0 && LOG_RAW_BEATS != 0) begin
            $fdisplay(fd, "%0d USER_TX lo128=%h keep=%h last=%0d", $time,
                      s_axi_tx_tdata[127:0], s_axi_tx_tkeep, s_axi_tx_tlast);
            $fflush(fd);
        end
    end


    // =================================================================
    // v1.0.7: UFC mesaj birlestirme + CIT cevabi
    //
    // TX'ten gelen 4 baytlik UFC kelimeleri sirayla toplanir: kelime0 = MSGID, kelime1 = LEN (bayt),
    // sonra ceil(LEN/4) veri kelimesi. 0000E003 (len=0) gelirse RESP_DELAY_CLKS sonra 0000E004 cevabi
    // verilir: kelime0 = 0000E004, kelime1 = 184, sonra 184 bayt veri (46 kelime) = toplam 48 UFC mesaji.
    // Her kelime ayri bir 4 baytlik UFC mesajidir (tvalid 1 clock, tkeep=0xF, tlast=1);
    // ufc_in_progress o clock'ta "islemde" seviyesine gider.
    //
    // Cevap govdesi (184 bayt) = 4 blok x 46 bayt; her blok:
    //   +0..7   8 bayt 0
    //   +8..21  14 x int8 sicaklik (derece C)
    //   +22..25 uint32 cihaz saati (saniye)
    //   +26..41 8 x uint16: [0] akim (mA), [1..7] gerilim (mV)
    //   +42..45 4 bayt reserved (0)
    // =================================================================
    localparam [31:0] ID_CIT_REQ  = 32'h0000E003;
    localparam [31:0] ID_CIT_RESP = 32'h0000E004;
    localparam integer RESP_BYTES = 184;
    localparam integer RESP_WORDS = 2 + RESP_BYTES / 4;   // 48

    reg [7:0]  rb [0:RESP_BYTES-1];
    reg [31:0] rw [0:RESP_WORDS-1];

    // temel sicaklik/gerilim tablolari (blok k icin: sicaklik + k, gerilim - 5*k)
    function [7:0] base_temp(input integer j);
        case (j)
            0: base_temp = 42;  1: base_temp = 45;  2: base_temp = 47;  3: base_temp = 44;
            4: base_temp = 51;  5: base_temp = 49;  6: base_temp = 46;  7: base_temp = 43;
            8: base_temp = 40;  9: base_temp = 38; 10: base_temp = 41; 11: base_temp = 39;
            12: base_temp = 36; default: base_temp = 35;
        endcase
    endfunction

    function [15:0] base_volt(input integer m);   // m = 1..7 (mV)
        case (m)
            1: base_volt = 12000; 2: base_volt = 5000; 3: base_volt = 3300; 4: base_volt = 2500;
            5: base_volt = 1800;  6: base_volt = 1200; default: base_volt = 1000;
        endcase
    endfunction

    // 16 bitlik alani rb[]'e yazar
    task put16(input integer off, input [15:0] v);
        begin
            if (FIELD_BIG_ENDIAN != 0) begin rb[off] = v[15:8]; rb[off+1] = v[7:0]; end
            else                       begin rb[off] = v[7:0];  rb[off+1] = v[15:8]; end
        end
    endtask
    task put32(input integer off, input [31:0] v);
        begin
            if (FIELD_BIG_ENDIAN != 0) begin rb[off] = v[31:24]; rb[off+1] = v[23:16]; rb[off+2] = v[15:8]; rb[off+3] = v[7:0]; end
            else                       begin rb[off] = v[7:0]; rb[off+1] = v[15:8]; rb[off+2] = v[23:16]; rb[off+3] = v[31:24]; end
        end
    endtask

    // cevap bayt dizisini ve UFC kelimelerini olusturur
    integer bi, bj, bm, bk;
    reg [31:0] secs;
    task build_resp;
        begin
            secs = UPTIME_OFFSET_S + ($time / 1000000000);
            for (bi = 0; bi < RESP_BYTES; bi = bi + 1) rb[bi] = 8'h00;
            for (bk = 0; bk < 4; bk = bk + 1) begin
                for (bj = 0; bj < 14; bj = bj + 1) rb[46*bk + 8 + bj] = base_temp(bj) + bk;
                put32(46*bk + 22, secs);
                put16(46*bk + 26, 1250 + 150*bk);                       // akim (mA)
                for (bm = 1; bm < 8; bm = bm + 1)
                    put16(46*bk + 26 + 2*bm, base_volt(bm) - 5*bk);     // gerilimler (mV)
            end
            rw[0] = ID_CIT_RESP;
            rw[1] = RESP_BYTES;
            for (bi = 0; bi < RESP_BYTES/4; bi = bi + 1) begin
                if (WORD_BIG_ENDIAN != 0)
                    rw[2+bi] = {rb[4*bi], rb[4*bi+1], rb[4*bi+2], rb[4*bi+3]};
                else
                    rw[2+bi] = {rb[4*bi+3], rb[4*bi+2], rb[4*bi+1], rb[4*bi]};
            end
        end
    endtask

    // ---- TX kelimelerini mesaja birlestir ----
    reg [1:0]  mst     = 2'd0;      // 0: ID bekle, 1: LEN bekle, 2: veri
    reg [31:0] m_id    = 32'd0;
    reg [31:0] m_len   = 32'd0;
    integer    m_words = 0;

    // ---- cevap durum makinesi ----
    integer rsp_state = 0;          // 0: bos, 1: gecikme, 2: gonderim
    integer dly_cnt   = 0;
    integer widx      = 0;
    integer gap_cnt   = 0;

    // tam bir mesaj toplandiginda cagrilir
    task msg_done(input [31:0] id, input [31:0] len);
        begin
            if (fd != 0) begin
                $fdisplay(fd, "%0d UFC_MSG id=%h len=%0d", $time, id, len);
                $fflush(fd);
            end
            if (RESP_ENABLE != 0 && id == ID_CIT_REQ && len == 0) begin
                if (rsp_state == 0) begin
                    build_resp;
                    rsp_state <= 1;
                    dly_cnt   <= RESP_DELAY_CLKS;
                    if (fd != 0) begin
                        $fdisplay(fd, "%0d UFC_RESP planlandi id=%h len=%0d (%0d kelime, %0d clk sonra)",
                                  $time, ID_CIT_RESP, RESP_BYTES, RESP_WORDS, RESP_DELAY_CLKS);
                        $fflush(fd);
                    end
                end else if (fd != 0) begin
                    $fdisplay(fd, "%0d UFC_RESP MESGUL: onceki cevap bitmeden yeni 0000E003 geldi, yok sayildi", $time);
                    $fflush(fd);
                end
            end else if (fd != 0) begin
                $fdisplay(fd, "%0d UFC_MSG yok sayildi (cevap tanimli degil)", $time);
                $fflush(fd);
            end
        end
    endtask

    always @(posedge clk) begin
        // --- 1) TX tarafi: kabul edilen kelimeyi mesaja ekle ---
        if (s_axi_ufc_tx_tvalid && busy) begin
            case (mst)
                2'd0: begin m_id <= s_axi_ufc_tx_tdata[31:0]; mst <= 2'd1; end
                2'd1: begin
                    m_len <= s_axi_ufc_tx_tdata[31:0];
                    if (s_axi_ufc_tx_tdata[31:0] == 0) begin
                        msg_done(m_id, 32'd0);
                        mst <= 2'd0;
                    end else begin
                        m_words <= (s_axi_ufc_tx_tdata[31:0] + 3) / 4;
                        mst     <= 2'd2;
                    end
                end
                default: begin
                    if (m_words <= 1) begin msg_done(m_id, m_len); mst <= 2'd0; end
                    m_words <= m_words - 1;
                end
            endcase
        end

        // --- 2) RX tarafi: varsayilan bos; cevap kelimelerini sir ile ver ---
        ufc_rx_tvalid_r <= 1'b0;
        ufc_rx_tlast_r  <= 1'b0;
        ufc_rx_tkeep_r  <= 24'd0;
        ufc_rx_tdata_r  <= 192'd0;
        ufc_ip_r        <= UFC_IN_PROGRESS_IDLE[0];
        case (rsp_state)
            1: begin
                if (dly_cnt <= 1) begin rsp_state <= 2; widx <= 0; gap_cnt <= 0; end
                else                   dly_cnt <= dly_cnt - 1;
            end
            2: begin
                if (gap_cnt > 0) gap_cnt <= gap_cnt - 1;
                else begin
                    ufc_rx_tdata_r  <= {160'd0, rw[widx]};
                    ufc_rx_tkeep_r  <= 24'h00000F;
                    ufc_rx_tlast_r  <= 1'b1;
                    ufc_rx_tvalid_r <= 1'b1;
                    ufc_ip_r        <= ~UFC_IN_PROGRESS_IDLE[0];
                    if (fd != 0) begin
                        $fdisplay(fd, "%0d UFC_RX idx=%0d word=%h", $time, widx, rw[widx]);
                        $fflush(fd);
                    end
                    widx    <= widx + 1;
                    gap_cnt <= RESP_GAP_CLKS;
                    if (widx == RESP_WORDS - 1) begin
                        rsp_state <= 0;
                        if (fd != 0) begin
                            $fdisplay(fd, "%0d UFC_RESP bitti id=%h", $time, ID_CIT_RESP);
                            $fflush(fd);
                        end
                    end
                end
            end
            default: ;
        endcase
    end


    // =================================================================
    // v1.0.7: Kullanici verisi mesaj birlestirme + HUZPAR ve KATSAYILAR (ID 0000E001) cozumu (gozlemci)
    //
    // Mesaj bicimi: ID (4 B) + LEN (4 B, yalnizca veri) + veri. Her beat'te yalnizca ALT 128 bit (16 bayt)
    // gecerlidir (tkeep[15:0]); ust 64 bit icin tkeep=0 beklenir. Beat'ler tlast'a kadar toplanir.
    // Mesaj ID 0000E001 ise alanlara ayrilip aurora_huzpar_<UNIT_NAME>.txt dosyasina, katsayilar
    // aurora_huzpar_katsayi_<UNIT_NAME>.txt dosyasina yazilir. Her mesaj icin obs dosyasina da MSG satiri yazilir.
    // Cevap uretilmez.
    //
    // Veri alanlari (index, boyut, tip) - little-endian:
    //    0 4 uint32 huzme ID | 4 2 uint16 sinyal isleme durumu (0 Bypass, 1 HO) | 6 2 uint16 alma huzmesi sayisi
    //    (HO: 4..96 4'er adim, Bypass: 960) | 8 4 darbe sayisi | 12 4 darbedeki ornek sayisi (4'un kati)
    //    16/20/24/28 4 x uint32 GAC kullanim maskeleri (bit 30,31 reserved) | 32 1 kart kullanim durumu
    //    (bit0 HO, bit1-3 HI-1..3) | 33 1 test modu (0 HO, 1 HI) | 34 22 reserved
    //    56'dan: katsayilar = huzme x 120 GAC x 4 kanal x (I,Q) x int16 (M x 1920 bayt); Bypass'ta yok.
    //    LEN = 56 + M*1920 (HO) | 56 (Bypass)
    // =================================================================
    localparam [31:0] ID_HUZPAR_KATSAYI = 32'h0000E001;

    reg [7:0] ub [0:MAX_MSG_BYTES-1];
    integer   ucount = 0;
    integer   ui, uk;
    reg [31:0] u_id, u_len;
    reg        u_hikeep = 1'b0;           // mesaj icinde ust 64 bit tkeep=1 goruldu mu

    integer fh = 0, fk = 0;
    reg [8*72-1:0] hname, kname;
    initial begin
        if (LOG_ENABLE != 0) begin
            $sformat(hname, "aurora_huzpar_%0s.txt", UNIT_NAME);
            $sformat(kname, "aurora_huzpar_katsayi_%0s.txt", UNIT_NAME);
            fh = $fopen(hname, "w");
            fk = $fopen(kname, "w");
            if (fh != 0) begin
                $fdisplay(fh, "# aurora_64b66b_vip SHOB HUZPAR ve KATSAYILAR (0000E001) gozlem logu (birim=%0s). Zamanlar ns.", UNIT_NAME);
                $fflush(fh);
            end
            if (fk != 0) begin
                $fdisplay(fk, "# katsayilar (birim=%0s): her satir bir (huzme, GAC); kanal basina I ve Q (int16)", UNIT_NAME);
                $fflush(fk);
            end
        end
    end

    // yardimci: ub[]'den little-endian okuma (mutlak bayt indeksi)
    function [15:0] u16(input integer o);
        u16 = {ub[o+1], ub[o]};
    endfunction
    function [31:0] u32(input integer o);
        u32 = {ub[o+3], ub[o+2], ub[o+1], ub[o]};
    endfunction

    reg [31:0] h_id, h_darbe, h_ornek, h_m0, h_m1, h_m2, h_m3;
    reg [15:0] h_durum, h_nbeam;
    reg [7:0]  h_kart, h_test;
    integer    h_exp, h_ncoef, h_hz, h_gac, h_k, h_o, h_avail, h_bad;
    reg signed [15:0] h_i, h_q;
    reg [8*10-1:0] h_dtxt;

    task huzpar_decode;
        begin
            if (ucount < 8 + 56) begin
                if (fh != 0) begin
                    $fdisplay(fh, "%0d HUZPAR_UYARI mesaj cok kisa: %0d bayt (en az 64 = ID+LEN+56 baslik gerekir)", $time, ucount);
                    $fflush(fh);
                end
            end else begin
                h_id    = u32(8);
                h_durum = u16(12);
                h_nbeam = u16(14);
                h_darbe = u32(16);
                h_ornek = u32(20);
                h_m0 = u32(24); h_m1 = u32(28); h_m2 = u32(32); h_m3 = u32(36);
                h_kart  = ub[40];
                h_test  = ub[41];
                if      (h_durum == 16'd0) h_dtxt = "Bypass";
                else if (h_durum == 16'd1) h_dtxt = "HO";
                else                       h_dtxt = "GECERSIZ";
                h_exp   = (h_durum == 16'd1) ? 56 + h_nbeam * 1920 : 56;
                h_ncoef = (ucount - 64) / 2;

                if (fh != 0) begin
                    $fwrite(fh, "%0d HUZPAR id=%h len=%0d huzme_id=%h durum=%0s alma_huzme=%0d darbe=%0d ornek=%0d ",
                            $time, u_id, u_len, h_id, h_dtxt, h_nbeam, h_darbe, h_ornek);
                    $fwrite(fh, "gac_maske=%h,%h,%h,%h kart=%h test_modu=%0d katsayi_int16=%0d reserved=",
                            h_m0, h_m1, h_m2, h_m3, h_kart, h_test, h_ncoef);
                    for (uk = 42; uk < 64; uk = uk + 1) begin
                        if (uk > 42) $fwrite(fh, " ");
                        $fwrite(fh, "%h", ub[8 + uk - 8 + 0]);   // ub[8+34 ...] = veri indexi 34..55
                    end
                    $fwrite(fh, "\n");

                    // ---- dogrulamalar ----
                    if (h_durum != 16'd0 && h_durum != 16'd1)
                        $fdisplay(fh, "%0d HUZPAR_UYARI sinyal isleme durumu gecersiz: %0d (0 Bypass, 1 HO)", $time, h_durum);
                    if (h_durum == 16'd1 && !(h_nbeam >= 4 && h_nbeam <= 96 && (h_nbeam % 4) == 0))
                        $fdisplay(fh, "%0d HUZPAR_UYARI HO'da alma huzmesi sayisi 4..96 (4'er adim) olmali: %0d", $time, h_nbeam);
                    if (h_durum == 16'd0 && h_nbeam != 16'd960)
                        $fdisplay(fh, "%0d HUZPAR_UYARI Bypass'ta alma huzmesi sayisi 960 olmali: %0d", $time, h_nbeam);
                    if (u_len != h_exp)
                        $fdisplay(fh, "%0d HUZPAR_UYARI len=%0d, beklenen %0d (%0s)", $time, u_len, h_exp,
                                  (h_durum == 16'd1) ? "56 + M*1920" : "Bypass: 56, katsayi yok");
                    if (h_durum == 16'd0 && u_len > 56)
                        $fdisplay(fh, "%0d HUZPAR_UYARI Bypass'ta katsayi gonderilmemeli (katsayi boyu 0)", $time);
                    if (h_darbe == 0)
                        $fdisplay(fh, "%0d HUZPAR_UYARI darbe sayisi 0 (>0 olmali)", $time);
                    if (h_ornek == 0 || (h_ornek % 4) != 0)
                        $fdisplay(fh, "%0d HUZPAR_UYARI darbedeki ornek sayisi >0 ve 4'un kati olmali: %0d", $time, h_ornek);
                    if (h_m0[31:30] != 0 || h_m1[31:30] != 0 || h_m2[31:30] != 0 || h_m3[31:30] != 0)
                        $fdisplay(fh, "%0d HUZPAR_UYARI GAC kullanim maskelerinin 30. ve 31. bitleri reserved (0 olmali)", $time);
                    if (h_test == 8'd1 && (h_kart & 8'h0E) != 0)
                        $fdisplay(fh, "%0d HUZPAR_UYARI test modu 1 iken HI kullanim durumlari 0 olmali: kart=%h", $time, h_kart);
                    h_bad = 0;
                    for (uk = 34; uk < 56; uk = uk + 1) if (ub[8 + uk] !== 8'h00) h_bad = 1;
                    if (h_bad) $fdisplay(fh, "%0d HUZPAR_UYARI reserved alani sifir degil", $time);
                    if (u_hikeep)
                        $fdisplay(fh, "%0d HUZPAR_UYARI ust 64 bit icin tkeep=1 goruldu (yalniz alt 128 bit kullanilir), yok sayildi", $time);
                    $fflush(fh);
                end

                // v1.0.7: bu HUZPAR icin huzme verisi gonderimini siraya al
                data_enqueue;

                // ---- katsayilar: huzme -> GAC -> kanal(1..4) -> I, Q (int16) ----
                if (h_durum == 16'd1 && fk != 0) begin
                    h_avail = ucount - 64;                      // katsayi icin gelen bayt
                    $fdisplay(fk, "%0d HUZPAR huzme_id=%h M=%0d katsayi_bayt=%0d", $time, h_id, h_nbeam, h_avail);
                    for (h_hz = 0; h_hz < h_nbeam; h_hz = h_hz + 1)
                        for (h_gac = 0; h_gac < 120; h_gac = h_gac + 1) begin
                            h_o = 8 + 56 + (h_hz * 120 + h_gac) * 16;
                            if (h_o - 8 - 56 + 16 <= h_avail) begin
                                $fwrite(fk, "huzme=%0d gac=%0d", h_hz + 1, h_gac + 1);
                                for (h_k = 0; h_k < 4; h_k = h_k + 1) begin
                                    h_i = u16(h_o + 4 * h_k);
                                    h_q = u16(h_o + 4 * h_k + 2);
                                    $fwrite(fk, " k%0d I=%0d Q=%0d", h_k + 1, h_i, h_q);
                                end
                                $fwrite(fk, "\n");
                            end else if (h_o - 8 - 56 < h_avail + 16 && fh != 0 && h_gac == 0 && h_hz == 0) begin
                                $fdisplay(fh, "%0d HUZPAR_UYARI katsayilar eksik geldi", $time);
                            end
                        end
                    $fflush(fk);
                end
            end
        end
    endtask

    task user_msg_done;
        begin
            if (ucount < 8) begin
                if (fd != 0) begin
                    $fdisplay(fd, "%0d MSG_KISA bayt=%0d (en az 8 bayt: ID+LEN gerekir), yok sayildi", $time, ucount);
                    $fflush(fd);
                end
            end else begin
                u_id  = u32(0);
                u_len = u32(4);
                if (fd != 0) begin
                    $fwrite(fd, "%0d MSG id=%h len=%0d data=", $time, u_id, u_len);
                    for (ui = 8; ui < ucount && ui < MAX_MSG_BYTES && (ui - 8) < LOG_DATA_BYTES; ui = ui + 1) begin
                        if (ui > 8) $fwrite(fd, " ");
                        $fwrite(fd, "%h", ub[ui]);
                    end
                    if ((ucount - 8) > LOG_DATA_BYTES) $fwrite(fd, " ... (toplam %0d veri bayti)", ucount - 8);
                    $fwrite(fd, "\n");
                    if (u_len != ucount - 8)
                        $fdisplay(fd, "%0d MSG_UYARI len=%0d ama %0d veri bayti geldi", $time, u_len, ucount - 8);
                    if (ucount > MAX_MSG_BYTES)
                        $fdisplay(fd, "%0d MSG_UYARI mesaj %0d bayt, tampon %0d bayt: fazlasi saklanmadi", $time, ucount, MAX_MSG_BYTES);
                    $fflush(fd);
                end
                if (u_id == ID_HUZPAR_KATSAYI) begin
                    if (fd != 0) begin
                        $fdisplay(fd, "%0d HUZPAR_MSG ayrintilar: aurora_huzpar_%0s.txt / aurora_huzpar_katsayi_%0s.txt", $time, UNIT_NAME, UNIT_NAME);
                        $fflush(fd);
                    end
                    // veri indeksi 0 = ub[8]; huzpar_decode ub[] mutlak indeks kullanir (8 + veri indeksi)
                    huzpar_decode;
                end
            end
            ucount   = 0;
            u_hikeep = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (s_axi_tx_tvalid && s_axi_tx_tready) begin
            for (ui = 0; ui < 16; ui = ui + 1)
                if (s_axi_tx_tkeep[ui]) begin
                    if (ucount < MAX_MSG_BYTES) ub[ucount] = s_axi_tx_tdata[8*ui +: 8];
                    ucount = ucount + 1;
                end
            if (s_axi_tx_tkeep[23:16] != 0) u_hikeep = 1'b1;
            if (s_axi_tx_tlast) user_msg_done;
        end
    end

    // =================================================================
    // v1.0.7: HUZME VERISI GONDERICISI (ID 00000002, SHOB -> SIFPGA)
    //
    // Her HUZPAR (0000E001) icin, DATA_DELAY_CLKS sonra tek bir mesaj gonderilir (kuyruklu: turlar sirayla).
    // Mesaj: ID(4)=00000002, LEN(4)=56 + M*N*8 + 960 + 16 + 16, ardindan govde. 192 bit AXI-S, beat'ler art arda,
    // son beat'te kismi tkeep. Hepsi little-endian.
    //   Govde: 56 B baslik | M*N*8 B ornek (ornek-ana: n -> m -> I,Q; her biri int32) | 960 B GAC SCIT | 16 B SHOB SCIT | 16 B reserved
    //   Baslik (VARSAYIM, ICD'de ayrintisi yok): 0 huzme_id(4) | 4 durum(2) | 6 M(2) | 8 darbe(4) | 12 ornek(4) | 16 N(4) | 20 shob_no(1) | 21.. sifir
    //   Ornek deseni (kendini tarif eder): kod = ((m+1)<<15) | (n & 7FFF); I = +carpan*kod, Q = -carpan*kod (int32)
    //     carpan: shob_1 icin 1, shob_2 icin 2 (SIFPGA toplarsa RSI'de 3*kod beklenir)
    //   N = darbe * ornek (huzme basina ornek sayisi), m = 0..M-1
    // =================================================================
    localparam DQ_DEPTH   = 8;
    localparam DATA_MSG_ID = 32'h00000002;
    localparam DATA_TAIL_BYTES = 960 + 16 + 16;
    localparam DMUL = (DATA_MUL != 0) ? DATA_MUL : ((UNIT_NAME == "shob_2") ? 2 : 1);

    reg [31:0] dq_id    [0:DQ_DEPTH-1];
    reg [31:0] dq_m     [0:DQ_DEPTH-1];
    reg [31:0] dq_darbe [0:DQ_DEPTH-1];
    reg [31:0] dq_ornek [0:DQ_DEPTH-1];
    reg [15:0] dq_durum [0:DQ_DEPTH-1];
    reg [63:0] dq_t     [0:DQ_DEPTH-1];
    integer dq_wr = 0;
    integer dq_rd = 0;
    integer dq_slot;

    integer fdat = 0;
    reg [8*64-1:0] fname_dat;
    initial begin
        if (LOG_ENABLE != 0 && DATA_ENABLE != 0) begin
            $sformat(fname_dat, "aurora_huzme_%0s.txt", UNIT_NAME);
            fdat = $fopen(fname_dat, "w");
            if (fdat != 0) begin
                $fdisplay(fdat, "# aurora_64b66b_vip huzme verisi gonderim logu (birim=%0s, carpan=%0d). Zamanlar ns.", UNIT_NAME, DMUL);
                $fflush(fdat);
            end
        end
    end

    task data_enqueue;
        begin
            if (DATA_ENABLE != 0) begin
                if (dq_wr - dq_rd >= DQ_DEPTH) begin
                    if (fdat != 0) begin
                        $fdisplay(fdat, "%0d HUZME_VERI_UYARI kuyruk dolu (%0d), bu HUZPAR icin veri gonderilmeyecek", $time, DQ_DEPTH);
                        $fflush(fdat);
                    end
                end else begin
                    dq_slot = dq_wr % DQ_DEPTH;
                    dq_id[dq_slot]    = h_id;
                    dq_m[dq_slot]     = h_nbeam;
                    dq_darbe[dq_slot] = h_darbe;
                    dq_ornek[dq_slot] = h_ornek;
                    dq_durum[dq_slot] = h_durum;
                    dq_t[dq_slot]     = $time;
                    dq_wr = dq_wr + 1;
                end
            end
        end
    endtask

    // aktif mesajin parametreleri
    reg [31:0] d_id, d_m, d_darbe, d_ornek, d_n, d_len;
    reg [15:0] d_durum;
    integer    d_samp_bytes;
    integer    d_total, d_beats, d_b, d_j, d_p, d_slot2;
    reg [31:0] d_code, d_val, d_s, d_nn, d_mm;
    reg [7:0]  d_by;
    reg [191:0] d_data;
    reg [23:0]  d_keep;
    reg [63:0] d_wait_until;

    // mesajin p. baytini uretir (p = 0: ID'nin ilk baytii)
    function [7:0] d_byte;
        input integer p;
        integer q, w, hp;
        reg [31:0] v;
        begin
            d_byte = 8'h00;
            if (p < 4) begin
                v = DATA_MSG_ID;  d_byte = v >> (8 * p);
            end else if (p < 8) begin
                v = d_len;        d_byte = v >> (8 * (p - 4));
            end else if (p < 64) begin
                hp = p - 8;
                case (hp)
                    0,1,2,3:     begin v = d_id;    d_byte = v >> (8 * hp); end
                    4,5:         begin v = {16'd0, d_durum}; d_byte = v >> (8 * (hp - 4)); end
                    6,7:         begin v = d_m;     d_byte = v >> (8 * (hp - 6)); end
                    8,9,10,11:   begin v = d_darbe; d_byte = v >> (8 * (hp - 8)); end
                    12,13,14,15: begin v = d_ornek; d_byte = v >> (8 * (hp - 12)); end
                    16,17,18,19: begin v = d_n;     d_byte = v >> (8 * (hp - 16)); end
                    20:          d_byte = DMUL;
                    default:     d_byte = 8'h00;
                endcase
            end else begin
                q = p - 64;
                if (q < d_samp_bytes) begin
                    d_s  = q / 8;
                    w    = q % 8;
                    d_nn = d_s / d_m;
                    d_mm = d_s - d_nn * d_m;
                    d_code = ((d_mm + 1) << 15) | (d_nn & 32'h7FFF);
                    if (w < 4) d_val = DMUL * d_code;
                    else       d_val = 32'd0 - (DMUL * d_code);
                    d_byte = d_val >> (8 * (w % 4));
                end
            end
        end
    endfunction

    initial begin
        forever begin
            @(posedge clk);
            if (DATA_ENABLE != 0 && dq_rd != dq_wr && channel_up) begin
                d_slot2 = dq_rd % DQ_DEPTH;
                d_wait_until = dq_t[d_slot2] + (DATA_DELAY_CLKS * 8);
                while ($time < d_wait_until) @(posedge clk);
                d_id = dq_id[d_slot2]; d_m = dq_m[d_slot2]; d_darbe = dq_darbe[d_slot2];
                d_ornek = dq_ornek[d_slot2]; d_durum = dq_durum[d_slot2];
                dq_rd = dq_rd + 1;
                d_n = d_darbe * d_ornek;
                d_samp_bytes = d_m * d_n * 8;
                d_len   = 56 + d_samp_bytes + DATA_TAIL_BYTES;
                d_total = 8 + d_len;
                d_beats = (d_total + 23) / 24;
                if (d_m == 0 || d_n == 0 || (d_m * d_n * 8 + 8 + 56 + DATA_TAIL_BYTES) > DATA_MAX_BYTES) begin
                    if (fdat != 0) begin
                        $fdisplay(fdat, "%0d HUZME_VERI_ATLANDI huzme_id=%h M=%0d N=%0d (bos ya da %0d bayt siniri asildi)", $time, d_id, d_m, d_n, DATA_MAX_BYTES);
                        $fflush(fdat);
                    end
                end else begin
                    if (fdat != 0) begin
                        $fdisplay(fdat, "%0d HUZME_VERI_BASLADI huzme_id=%h M=%0d darbe=%0d ornek=%0d N=%0d carpan=%0d mesaj_bayt=%0d len=%0d beat=%0d",
                                  $time, d_id, d_m, d_darbe, d_ornek, d_n, DMUL, d_total, d_len, d_beats);
                        $fflush(fdat);
                    end
                    for (d_b = 0; d_b < d_beats; d_b = d_b + 1) begin
                        d_data = 192'd0; d_keep = 24'd0;
                        for (d_j = 0; d_j < 24; d_j = d_j + 1) begin
                            d_p = d_b * 24 + d_j;
                            if (d_p < d_total) begin
                                d_by = d_byte(d_p);
                                d_data[8*d_j +: 8] = d_by;
                                d_keep[d_j] = 1'b1;
                            end
                        end
                        rx_tdata_r  <= d_data;
                        rx_tkeep_r  <= d_keep;
                        rx_tvalid_r <= 1'b1;
                        rx_tlast_r  <= (d_b == d_beats - 1);
                        @(posedge clk);
                    end
                    rx_tdata_r  <= 192'd0;
                    rx_tkeep_r  <= 24'd0;
                    rx_tvalid_r <= 1'b0;
                    rx_tlast_r  <= 1'b0;
                    if (fdat != 0) begin
                        $fdisplay(fdat, "%0d HUZME_VERI_BITTI huzme_id=%h M=%0d N=%0d beat=%0d", $time, d_id, d_m, d_n, d_beats);
                        $fflush(fdat);
                    end
                end
            end
        end
    end

    // ---- link durumu degisimleri ----
    reg cu_d = 1'b0;
    always @(posedge clk) begin
        cu_d <= channel_up;
        if (fd != 0 && channel_up !== cu_d) begin
            $fdisplay(fd, "%0d LINK channel_up=%0d lane_up=%b", $time, channel_up, lane_up);
            $fflush(fd);
        end
    end

`else
    // =================================================================
    // SADE GOVDE (BD ayristirmasi icin): tum cikislar sabit
    // =================================================================
    initial $display("[AURORA] UYARI: SADE GOVDE (VIP_STUB) aktif - saat/link/log YOK.");
    assign s_axi_tx_tready = 1'b1;
    assign m_axi_rx_tdata = 192'd0;  assign m_axi_rx_tkeep = 24'd0;
    assign m_axi_rx_tlast = 1'b0;    assign m_axi_rx_tvalid = 1'b0;
    assign s_axi_ufc_tx_tready = 1'b0;
    assign m_axi_ufc_rx_tdata = 192'd0; assign m_axi_ufc_rx_tkeep = 24'd0;
    assign m_axi_ufc_rx_tlast = 1'b0;   assign m_axi_ufc_rx_tvalid = 1'b0;
    assign ufc_in_progress = UFC_IN_PROGRESS_IDLE[0];
    assign txp = 3'b000;  assign txn = 3'b111;
    assign gt_refclk1_out = gt_refclk1_p;
    assign hard_err = 1'b0; assign soft_err = 1'b0;
    assign channel_up = 1'b0; assign lane_up = 3'b000;
    assign crc_pass_fail_n = 1'b1; assign crc_valid = 1'b0;
    assign user_clk_out = gt_refclk1_p; assign sync_clk_out = gt_refclk1_p; assign tx_out_clk = gt_refclk1_p;
    assign mmcm_not_locked_out = 1'b1;
    assign gt_pll_lock = 1'b0; assign link_reset_out = 1'b1;
    assign gt_powergood = 3'b000; assign sys_reset_out = 1'b1; assign gt_reset_out = 1'b1;
`endif

endmodule
