`timescale 1ns / 1ps

// =====================================================================
// aurora_64b66b_vip  (v1.0.5)  -  Aurora 64B/66B IP'sinin yerine konan GOZLEMCI (observer) VIP
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
// v1.0.5: CIT cevabi. SHOB'a 0000E003 (len=0) istegi gelince 1 us sonra 0000E004 (len=184) cevabi,
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
    // ---- v1.0.5: cevap uretimi ----
    parameter RESP_ENABLE      = 1,        // 0: cevap uretme (yalnizca gozlemci)
    parameter RESP_DELAY_CLKS  = 125,      // istekten ilk cevap kelimesine bekleme (125 clk = 1 us)
    parameter RESP_GAP_CLKS    = 1,        // cevap kelimeleri arasi bos clock sayisi
    parameter FIELD_BIG_ENDIAN = 0,        // cevaptaki uint16/uint32 alanlari: 0 = little-endian
    parameter WORD_BIG_ENDIAN  = 0,        // 4 baytlik kelime paketleme: 0 = ilk bayt tdata[7:0]
    parameter UPTIME_OFFSET_S  = 273600    // cihaz saati baslangici (saniye); + simulasyon suresi
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
    assign m_axi_rx_tdata      = 192'd0;
    assign m_axi_rx_tkeep      = 24'd0;
    assign m_axi_rx_tlast      = 1'b0;
    assign m_axi_rx_tvalid     = 1'b0;
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
            $display("[AURORA %0s] DAVRANIS SURUMU aktif (v1.0.5). Log dosyasi: %0s", UNIT_NAME, fname);
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
        if (s_axi_tx_tvalid && s_axi_tx_tready && fd != 0) begin
            $fdisplay(fd, "%0d USER_TX lo128=%h keep=%h last=%0d", $time,
                      s_axi_tx_tdata[127:0], s_axi_tx_tkeep, s_axi_tx_tlast);
            $fflush(fd);
        end
    end


    // =================================================================
    // v1.0.5: UFC mesaj birlestirme + CIT cevabi
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
