`timescale 1ns / 1ps

// =====================================================================
// beam_if : Huzme basi (HB) sinyali icin kucuk arayuz.
//
//  - obs : GOZLENEN sinyal. Tasarimdaki gercek HuzmeBasi telinde o an ne varsa o.
//          `99999999` (HB bekle) komutu bunu izler. Girisi sim_model_cpu'daki
//          `huzme_basi_obs` portundan gelir.
//  - gen : URETILEN sinyal. Senaryo modunda `77777777` komutuyla VIP'in verdigi
//          darbe. Cikisi sim_model_cpu'daki `huzme_basi_gen` portuna gider.
//  - clk : Darbeyi ve beklemeyi hizalamak icin kullanilan saat (user_clk).
// =====================================================================
interface beam_if (input logic clk);
    logic obs;
    logic gen = 1'b0;   // bosta seviyesi (aktif-yuksek varsayimi); aktif-dusuk icin sim_model_cpu duzeltir
endinterface
