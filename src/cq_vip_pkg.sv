`timescale 1ns / 1ps

package cq_vip_pkg;

class tlp_item;
    bit [7:0] tlp_packet[];  // 16B descriptor + msg_id(4) + length(4) + payload(N)
    bit [3:0] first_be;
    bit [3:0] last_be;

    function new(int total_len);
        this.tlp_packet = new[total_len];
        this.first_be   = 4'b1111;
        this.last_be    = 4'b1111;
    endfunction
endclass


class generator;
    mailbox #(tlp_item) mbx;
    string file_name;

    function new(mailbox #(tlp_item) mbx, string file_name = "input_data.txt");
        this.mbx = mbx;
        this.file_name = file_name;
    endfunction

    task run();
        int fd, status;
        bit [63:0] address;
        bit [31:0] msg_id;
        int        data_len;
        bit [7:0]  read_byte;
        int user_payload_bytes, dword_count, total_tlp_bytes;
        bit [7:0] desc[16];
        tlp_item tr;

        fd = $fopen(file_name, "r");
        if (fd == 0) $fatal(1, "[GEN-FATAL] Dosya bulunamadi: %s", file_name);

        while (!$feof(fd)) begin
            status = $fscanf(fd, "%h %h %d", address, msg_id, data_len);
            if (status <= 0) break;

            if ((data_len % 4) != 0) begin
                $error("[GEN] data_len (%0d) 4'un kati degil! Mesaj atlaniyor.", data_len);
                for (int i = 0; i < data_len; i++) status = $fscanf(fd, "%h", read_byte);
                continue;
            end

            user_payload_bytes = 4 + 4 + data_len;
            dword_count        = user_payload_bytes / 4;
            total_tlp_bytes    = 16 + user_payload_bytes;
            tr = new(total_tlp_bytes);

            // CQ descriptor (16B): DW0/1 adres, DW2 dword count + req type (MemWr=0001)
            for (int i = 0; i < 16; i++) desc[i] = 8'h00;
            desc[0] = {address[7:2], 2'b00};
            desc[1] = address[15:8];
            desc[2] = address[23:16];
            desc[3] = address[31:24];
            desc[4] = address[39:32];
            desc[5] = address[47:40];
            desc[6] = address[55:48];
            desc[7] = address[63:56];
            desc[8] = dword_count[7:0];
            desc[9] = {1'b0, 4'b0001, dword_count[10:8]};
            // TODO: requester id (10,11), tag (12), target fn (13), bar_id/aperture/TC/attr (14,15)

            for (int i = 0; i < 16; i++) tr.tlp_packet[i] = desc[i];
            for (int i = 0; i < 4; i++) tr.tlp_packet[16+i] = msg_id[8*i +: 8];
            for (int i = 0; i < 4; i++) tr.tlp_packet[20+i] = data_len[8*i +: 8];
            for (int i = 0; i < data_len; i++) begin
                status = $fscanf(fd, "%h", read_byte);
                tr.tlp_packet[24+i] = read_byte;
            end

            mbx.put(tr);
            $display("[GEN] TLP -> Addr: %h | MsgID: %h | Len: %0d | TotalTLP: %0d byte",
                      address, msg_id, data_len, total_tlp_bytes);
        end
        $fclose(fd);
        $display("[GEN] Tum TLP paketleri uretildi.");
    endtask
endclass


class driver #(int DATA_WIDTH = 256, int TUSER_WIDTH = 88, int KEEP_GRAN = 4);
    localparam int DATA_BYTES = DATA_WIDTH / 8;
    localparam int KEEP_WIDTH = DATA_BYTES / KEEP_GRAN;
    // TUSER >= 88 -> UltraScale+ CQ duzeni, aksi halde basit (eski) duzen
    localparam bit US_PLUS_CQ = (TUSER_WIDTH >= 88);

    mailbox #(tlp_item) mbx;
    virtual axis_tx_if #(DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN) vif;

    function new(virtual axis_tx_if #(DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN) vif,
                 mailbox #(tlp_item) mbx);
        this.mbx = mbx;
        this.vif = vif;
    endfunction

    task reset();
        vif.tvalid <= 1'b0;
        vif.tdata  <= '0;
        vif.tlast  <= 1'b0;
        vif.tkeep  <= '0;
        vif.tuser  <= '0;
        wait (vif.rst_n === 1'b1);
        $display("[DRIVER] Reset kalkti (DATA=%0d TUSER=%0d KEEP_GRAN=%0d)",
                 DATA_WIDTH, TUSER_WIDTH, KEEP_GRAN);
    endtask

    task run();
        tlp_item msg;
        forever begin
            mbx.get(msg);
            drive_item(msg);
        end
    endtask

    function automatic bit [TUSER_WIDTH-1:0] build_user(tlp_item msg, bit first_beat, bit last_beat,
                                                        int tlp_off, int n_bytes);
        bit [TUSER_WIDTH-1:0] user = '0;
        if (US_PLUS_CQ) begin
            // PG213 CQ tuser (256-bit): first_be[3:0] last_be[7:4] byte_en[39:8] sop[40]
            // TODO: byte_en / parity duzenini PG213'ten dogrula.
            if (first_beat) begin
                user[3:0] = msg.first_be;
                user[7:4] = msg.last_be;
                user[40]  = 1'b1;
            end
            for (int b = 0; b < n_bytes; b++)
                if (tlp_off + b >= 16) user[8 + b] = 1'b1;  // sadece payload baytlari
        end else begin
            if (first_beat) user[3:0] = msg.first_be;
            if (last_beat)  user[7:4] = msg.last_be;
        end
        return user;
    endfunction

    task drive_item(tlp_item msg);
        bit [DATA_WIDTH-1:0] word;
        bit [KEEP_WIDTH-1:0] keep;
        int total = msg.tlp_packet.size();
        int off   = 0;
        int n_bytes;
        bit first_beat = 1'b1;
        bit last_beat;

        @(posedge vif.aclk);
        while (off < total) begin
            n_bytes   = ((total - off) < DATA_BYTES) ? (total - off) : DATA_BYTES;
            last_beat = (off + n_bytes >= total);

            word = '0;
            keep = '0;
            for (int b = 0; b < n_bytes; b++) begin
                word[b*8 +: 8]    = msg.tlp_packet[off + b];
                keep[b / KEEP_GRAN] = 1'b1;
            end

            vif.tvalid <= 1'b1;
            vif.tdata  <= word;
            vif.tkeep  <= keep;
            vif.tlast  <= last_beat;
            vif.tuser  <= build_user(msg, first_beat, last_beat, off, n_bytes);

            @(posedge vif.aclk);
            if (vif.tready === 1'b1) begin   // beat kabul edildi
                off += n_bytes;
                first_beat = 1'b0;
            end
        end

        vif.tvalid <= 1'b0;
        vif.tlast  <= 1'b0;
        vif.tdata  <= '0;
        vif.tkeep  <= '0;
        vif.tuser  <= '0;
        $display("[DRIVER] TLP surulduk (%0d byte)", total);
    endtask
endclass

endpackage
