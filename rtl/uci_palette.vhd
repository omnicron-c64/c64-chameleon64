-- -----------------------------------------------------------------------
-- Ultimate Command Interface ($DF1C-$DF1F) + custom palette loader
--
-- UCI registers (only when uci_enable = '1'):
--   $DF1C W: control  bit0 PUSH_CMD, bit1 DATA_ACC, bit2 ABORT, bit3 CLR_ERR
--         R: status   bit7 DATA_AV, bit6 STAT_AV, bit5-4 STATE, bit3 ERROR
--   $DF1D W: command byte          R: identification $C9
--   $DF1E R: response data
--   $DF1F R: status string
--
-- Target $F0 (core-local palette):
--   F0 01 idx R G B / F0 02 R G B x16 / F0 03 n
-- Every other target (e.g. $01 Ultimate DOS) is handed to the menu firmware
-- over SPI (user_io select, commands $C0-$C5):
--   C0 R: flags, cmd_len            C1 R: flags, cmd bytes
--   C2 W: response data             C3 W: status string
--   C4 W: more, rlen_lo, rlen_hi, slen  (commit packet)
--   C5 W: REU base address (4 bytes, little endian)
--   flags: bit0 command pending, bit1 waiting for next packet (DATA_ACC on "more"), bit2 abort
--
-- .vpl (VICE palette) text files are decoded as they are downloaded.
-- -----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uci_palette is
port (
	clk          : in  std_logic;
	reset        : in  std_logic;
	uci_enable   : in  std_logic;

	-- expansion port
	phi          : in  std_logic;
	iof          : in  std_logic;
	addr         : in  std_logic_vector(15 downto 0);
	rnw          : in  std_logic;
	din          : in  std_logic_vector(7 downto 0);
	dout         : out std_logic_vector(7 downto 0);
	oe           : out std_logic;

	-- .vpl download
	vpl_download : in  std_logic;
	vpl_wr       : in  std_logic;
	vpl_data     : in  std_logic_vector(7 downto 0);

	-- palette control
	menu_palette : in  unsigned(2 downto 0);
	palette_sel  : out unsigned(3 downto 0);
	pal_we       : out std_logic;
	pal_idx      : out unsigned(3 downto 0);
	pal_rgb      : out std_logic_vector(23 downto 0);

	-- firmware link (SPI, user_io select)
	spi_sck      : in  std_logic := '0';
	spi_ss       : in  std_logic := '1';
	spi_mosi     : in  std_logic := '0';
	spi_dout     : out std_logic_vector(7 downto 0);
	reu_base     : out std_logic_vector(23 downto 0);
	reu_busy     : in  std_logic := '0'
);
end uci_palette;

architecture rtl of uci_palette is

	constant MSG_OK  : string := "00,OK";
	constant MSG_ERR : string := "21,NOT SUPPORTED";

	function msg_byte(sel : std_logic; ptr : unsigned(4 downto 0)) return std_logic_vector is
		variable p : integer;
	begin
		p := to_integer(ptr);
		if sel = '0' then
			if p < MSG_OK'length then
				return std_logic_vector(to_unsigned(character'pos(MSG_OK(p+1)), 8));
			end if;
		else
			if p < MSG_ERR'length then
				return std_logic_vector(to_unsigned(character'pos(MSG_ERR(p+1)), 8));
			end if;
		end if;
		return x"00";
	end function;

	function hexval(c : std_logic_vector(7 downto 0)) return integer is
		variable v : integer;
	begin
		v := to_integer(unsigned(c));
		if v >= 48 and v <= 57 then return v - 48;
		elsif v >= 65 and v <= 70 then return v - 55;
		elsif v >= 97 and v <= 102 then return v - 87;
		end if;
		return -1;
	end function;

	-- shared buffer: $000-$0FF command, $100-$2FF response, $300-$3FF status
	type ram_t is array(0 to 1023) of std_logic_vector(7 downto 0);
	shared variable ram : ram_t;
	signal a_addr    : unsigned(9 downto 0);
	signal a_we      : std_logic;
	signal a_d       : std_logic_vector(7 downto 0);
	signal a_q       : std_logic_vector(7 downto 0);
	signal b_addr    : unsigned(9 downto 0);
	signal b_we      : std_logic;
	signal b_d       : std_logic_vector(7 downto 0);
	signal b_q       : std_logic_vector(7 downto 0);

	-- bus
	signal cs        : std_logic;
	signal phi_d     : std_logic;
	signal cs_d      : std_logic;
	signal rnw_d     : std_logic;
	signal a_dl      : std_logic_vector(1 downto 0);
	signal din_d     : std_logic_vector(7 downto 0);

	-- UCI state
	signal state     : std_logic_vector(1 downto 0);
	signal err       : std_logic;
	signal stat_av   : std_logic;
	signal data_av   : std_logic;
	signal local_msg : std_logic;  -- status comes from the local message ROM (target $F0)
	signal msg_sel   : std_logic;
	signal msg_ptr   : unsigned(4 downto 0);
	signal stat_byte : std_logic_vector(7 downto 0);
	signal cnt       : unsigned(8 downto 0);
	signal target    : std_logic_vector(7 downto 0);
	signal cmd       : std_logic_vector(7 downto 0);
	signal arg0      : std_logic_vector(7 downto 0);
	signal u_r, u_g  : std_logic_vector(7 downto 0);
	signal comp      : unsigned(1 downto 0);
	signal col       : unsigned(4 downto 0);

	-- firmware handshake (clk domain)
	signal dos_pending : std_logic := '0';
	signal dos_wait    : std_logic := '0';
	signal dos_abort   : std_logic := '0';
	signal cmd_len     : unsigned(8 downto 0) := (others => '0');
	signal rp, rlen    : unsigned(9 downto 0) := (others => '0');
	signal sp, slen    : unsigned(7 downto 0) := (others => '0');
	signal cmt_s       : std_logic_vector(2 downto 0) := "000";
	signal cmt_ack     : std_logic := '0';   -- echoes s_cmt_t once the commit has been applied

	-- SPI domain
	signal s_bit     : unsigned(2 downto 0);
	signal s_byte    : unsigned(9 downto 0);
	signal s_sbuf    : std_logic_vector(6 downto 0);
	signal s_cmd     : std_logic_vector(7 downto 0);
	signal s_flags   : std_logic_vector(7 downto 0);
	signal s_flags_m : std_logic_vector(7 downto 0);
	signal s_clen    : std_logic_vector(7 downto 0);
	signal s_clen_m  : std_logic_vector(7 downto 0);
	signal s_more    : std_logic := '0';
	signal s_rlen    : unsigned(9 downto 0) := (others => '0');
	signal s_slen    : unsigned(7 downto 0) := (others => '0');
	signal s_cmt_t   : std_logic := '0';
	signal s_reu     : std_logic_vector(23 downto 0) := (others => '0');
	signal s_ack_m   : std_logic := '0';
	signal s_ack     : std_logic := '0';

	-- .vpl parser
	signal dl_d      : std_logic;
	signal vp_comment: std_logic;
	signal vp_in_tok : std_logic;
	signal vp_val    : std_logic_vector(7 downto 0);
	signal vp_ntok   : unsigned(2 downto 0);
	signal vp_r, vp_g, vp_b : std_logic_vector(7 downto 0);
	signal vp_eol    : std_logic;
	signal vp_col    : unsigned(4 downto 0);

	-- palette select
	signal sel_reg   : unsigned(3 downto 0) := "0000";
	signal menu_d    : unsigned(2 downto 0) := "000";

begin

	------------------------------------------------------------------
	-- dual-clock buffer RAM
	------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if a_we = '1' then
				ram(to_integer(a_addr)) := a_d;
			end if;
			a_q <= ram(to_integer(a_addr));
		end if;
	end process;

	process(spi_sck)
	begin
		if rising_edge(spi_sck) then
			if b_we = '1' then
				ram(to_integer(b_addr)) := b_d;
			end if;
			b_q <= ram(to_integer(b_addr));
		end if;
	end process;

	------------------------------------------------------------------
	-- C64 bus
	------------------------------------------------------------------
	cs <= '1' when uci_enable = '1' and phi = '1' and iof = '1' and addr(7 downto 2) = "000111" else '0';
	oe <= cs and rnw;

	stat_byte <= msg_byte(msg_sel, msg_ptr) when local_msg = '1' and stat_av = '1' else
	             a_q when stat_av = '1' else x"00";

	with addr(1 downto 0) select dout <=
		data_av & stat_av & state & err & "000" when "00",
		x"C9"                                   when "01",
		a_q                                     when "10",
		stat_byte                               when others;

	palette_sel <= sel_reg;

	-- port A: command byte writes, otherwise reads the response or status byte at the read pointer
	a_we   <= '1' when phi = '0' and phi_d = '1' and cs_d = '1' and rnw_d = '0' and a_dl = "01" and
	                   state = "00" and cnt(8) = '0' else '0';
	a_d    <= din_d;
	a_addr <= unsigned'("00") & cnt(7 downto 0) when a_we = '1' else
	          unsigned'("11") & sp when addr(0) = '1' else
	          to_unsigned(256, 10) + rp;

	process(clk)
		variable h : integer;
		variable eol, tok_end : boolean;
		variable ok : boolean;
	begin
		if rising_edge(clk) then
			pal_we <= '0';

			menu_d <= menu_palette;
			if menu_palette /= menu_d then
				sel_reg <= '0' & menu_palette;
			end if;

			------------------------------------------------------------------
			-- packet committed by the firmware
			------------------------------------------------------------------
			cmt_s <= cmt_s(1 downto 0) & s_cmt_t;
			if cmt_s(2) /= cmt_s(1) then
				cmt_ack     <= cmt_s(1);
				dos_pending <= '0';
				dos_wait    <= '0';
				rlen      <= s_rlen;
				slen      <= s_slen;
				rp        <= (others => '0');
				sp        <= (others => '0');
				local_msg <= '0';
				data_av   <= '0';
				if s_rlen /= 0 then data_av <= '1'; end if;
				stat_av   <= '0';
				if s_slen /= 0 then stat_av <= '1'; end if;
				if s_more = '1' then state <= "11"; else state <= "10"; end if;
			end if;

			------------------------------------------------------------------
			-- UCI bus access, acted on at the end of phi2
			------------------------------------------------------------------
			phi_d <= phi;
			if cs = '1' then
				cs_d  <= '1';
				rnw_d <= rnw;
				a_dl  <= addr(1 downto 0);
				din_d <= din;
			end if;
			if phi = '0' and phi_d = '1' then
				cs_d <= '0';
			end if;

			if reset = '1' then
				state   <= "00";
				err     <= '0';
				stat_av <= '0';
				data_av <= '0';
				cnt     <= (others => '0');
				cs_d    <= '0';
				dos_pending <= '0';
				dos_wait    <= '0';
			elsif phi = '0' and phi_d = '1' and cs_d = '1' then
				if rnw_d = '0' then
					case a_dl is
					when "00" =>
						if din_d(3) = '1' then
							err <= '0';
						end if;
						if din_d(2) = '1' then              -- abort
							state <= "00"; stat_av <= '0'; data_av <= '0'; cnt <= (others => '0');
							dos_pending <= '0'; dos_wait <= '0';
							if dos_pending = '1' or dos_wait = '1' or state /= "00" then dos_abort <= '1'; end if;
						elsif din_d(1) = '1' then           -- data accepted
							if state = "11" then            -- more to come: firmware sends the next packet
								state <= "01"; stat_av <= '0'; data_av <= '0';
								dos_wait <= '1';
							elsif state /= "00" then
								state <= "00"; stat_av <= '0'; data_av <= '0'; cnt <= (others => '0');
							end if;
						elsif din_d(0) = '1' then           -- push command
							if state = "00" then
								dos_abort <= '0';
								if target = x"F0" then
									ok := (cmd = x"01" and cnt >= 6) or
									      (cmd = x"02" and cnt >= 5) or
									      (cmd = x"03" and cnt >= 3 and unsigned(arg0) <= 8);
									if ok then
										msg_sel <= '0';
										if cmd = x"03" then
											sel_reg <= unsigned(arg0(3 downto 0));
										else
											sel_reg <= "1000";
										end if;
									else
										msg_sel <= '1';
									end if;
									local_msg <= '1';
									state   <= "10";
									stat_av <= '1';
									data_av <= '0';
									msg_ptr <= (others => '0');
									cnt     <= (others => '0');
								else
									cmd_len     <= cnt;
									dos_pending <= '1';
									state       <= "01";
								end if;
							else
								err <= '1';
							end if;
						end if;

					when "01" =>                            -- command byte
						if state /= "00" then
							err <= '1';
						else
							if cnt(8) = '0' then
								cnt <= cnt + 1;
							end if;
							if cnt = 0 then
								target <= din_d;
							elsif cnt = 1 then
								cmd  <= din_d;
								comp <= "00";
								col  <= (others => '0');
							elsif target = x"F0" then
								if cmd = x"01" then
									case to_integer(cnt) is
									when 2 => arg0 <= din_d;
									when 3 => u_r  <= din_d;
									when 4 => u_g  <= din_d;
									when 5 =>
										pal_we  <= '1';
										pal_idx <= unsigned(arg0(3 downto 0));
										pal_rgb <= u_r & u_g & din_d;
									when others => null;
									end case;
								elsif cmd = x"02" then
									if comp = 0 then
										u_r <= din_d; comp <= "01";
									elsif comp = 1 then
										u_g <= din_d; comp <= "10";
									else
										comp <= "00";
										if col(4) = '0' then
											pal_we  <= '1';
											pal_idx <= col(3 downto 0);
											pal_rgb <= u_r & u_g & din_d;
											col <= col + 1;
										end if;
									end if;
								elsif cmd = x"03" and cnt = 2 then
									arg0 <= din_d;
								end if;
							end if;
						end if;

					when others =>
						null;
					end case;
				else
					if a_dl = "10" and data_av = '1' then   -- response data pop
						if rp + 1 >= rlen then
							data_av <= '0';
						end if;
						rp <= rp + 1;
					end if;
					if a_dl = "11" and stat_av = '1' then   -- status string pop
						if local_msg = '1' then
							if (msg_sel = '0' and msg_ptr = MSG_OK'length-1) or
							   (msg_sel = '1' and msg_ptr = MSG_ERR'length-1) then
								stat_av <= '0';
							end if;
							msg_ptr <= msg_ptr + 1;
						else
							if sp + 1 >= slen then
								stat_av <= '0';
							end if;
							sp <= sp + 1;
						end if;
					end if;
				end if;
			end if;

			if uci_enable = '0' then
				state   <= "00";
				stat_av <= '0';
				data_av <= '0';
				cnt     <= (others => '0');
				dos_pending <= '0';
				dos_wait    <= '0';
			end if;

			------------------------------------------------------------------
			-- .vpl text decoder
			------------------------------------------------------------------
			dl_d <= vpl_download;
			if vpl_download = '1' and dl_d = '0' then
				vp_comment <= '0';
				vp_in_tok  <= '0';
				vp_val     <= (others => '0');
				vp_ntok    <= (others => '0');
				vp_eol     <= '0';
				vp_col     <= (others => '0');
			elsif vp_eol = '1' then
				vp_eol  <= '0';
				vp_ntok <= (others => '0');
				if vp_ntok >= 3 and vp_col(4) = '0' then
					pal_we  <= '1';
					pal_idx <= vp_col(3 downto 0);
					pal_rgb <= vp_r & vp_g & vp_b;
					vp_col  <= vp_col + 1;
					sel_reg <= "1000";
				end if;
			elsif (vpl_download = '1' and vpl_wr = '1') or (vpl_download = '0' and dl_d = '1') then
				eol := false;
				tok_end := false;
				h := -1;
				if vpl_download = '0' then
					eol := true;
					tok_end := true;
				elsif vp_comment = '1' then
					if vpl_data = x"0A" or vpl_data = x"0D" then
						vp_comment <= '0';
						eol := true;
					end if;
				elsif vpl_data = x"23" then
					vp_comment <= '1';
					eol := true;
					tok_end := true;
				elsif vpl_data = x"0A" or vpl_data = x"0D" then
					eol := true;
					tok_end := true;
				else
					h := hexval(vpl_data);
					if h >= 0 then
						vp_val    <= vp_val(3 downto 0) & std_logic_vector(to_unsigned(h, 4));
						vp_in_tok <= '1';
					else
						tok_end := true;
					end if;
				end if;

				if tok_end and vp_in_tok = '1' then
					case to_integer(vp_ntok) is
					when 0 => vp_r <= vp_val;
					when 1 => vp_g <= vp_val;
					when 2 => vp_b <= vp_val;
					when others => null;
					end case;
					if vp_ntok /= 7 then
						vp_ntok <= vp_ntok + 1;
					end if;
					vp_in_tok <= '0';
					vp_val    <= (others => '0');
				end if;
				if eol then
					vp_eol <= '1';
				end if;
			end if;
		end if;
	end process;

	------------------------------------------------------------------
	-- SPI side (firmware): shadow slave on the user_io select line
	------------------------------------------------------------------
	reu_base <= s_reu;

	-- byte returned for the next SPI byte: flags first, then per command
	spi_dout <= s_flags   when s_byte = 0 else
	            s_clen    when s_cmd = x"C0" and s_byte = 1 else
	            b_q       when s_cmd = x"C1" else
	            x"00";

	-- read address for C1 (command bytes), write address for C2/C3
	b_addr <= (unsigned'("00") & s_byte(7 downto 0)) - 1      when s_cmd = x"C1" else
	          to_unsigned(256, 10) + (s_byte - 1)             when s_cmd = x"C2" else
	          unsigned'("11") & (s_byte(7 downto 0) - 1)      when s_cmd = x"C3" else
	          (others => '0');
	b_d  <= s_sbuf & spi_mosi;
	b_we <= '1' when s_bit = 7 and s_byte /= 0 and
	                 ((s_cmd = x"C2" and s_byte <= 512) or (s_cmd = x"C3" and s_byte <= 256)) else '0';

	process(spi_sck, spi_ss)
	begin
		if spi_ss = '1' then
			s_bit  <= (others => '0');
			s_byte <= (others => '0');
			s_cmd  <= (others => '0');
		elsif rising_edge(spi_sck) then
			-- handshake flags from the C64 side (two stages). Until the last commit has
			-- been applied on the C64 side, report nothing pending/accepted, so the
			-- firmware never acts on a stale command or a stale DATA_ACC.
			s_ack_m   <= cmt_ack;
			s_ack     <= s_ack_m;
			s_flags_m <= reu_busy & "0000" & dos_abort & dos_wait & dos_pending;
			if s_ack /= s_cmt_t then
				s_flags <= s_flags_m(7) & "0000" & s_flags_m(2) & "00";
			else
				s_flags <= s_flags_m;
			end if;
			s_clen_m  <= std_logic_vector(cmd_len(7 downto 0));
			if cmd_len(8) = '1' then s_clen_m <= x"FF"; end if;
			s_clen    <= s_clen_m;

			s_sbuf <= s_sbuf(5 downto 0) & spi_mosi;
			s_bit  <= s_bit + 1;
			if s_bit = 7 then
				if s_byte /= 1023 then
					s_byte <= s_byte + 1;
				end if;
				if s_byte = 0 then
					s_cmd <= s_sbuf & spi_mosi;
				elsif s_cmd = x"C4" then
					case to_integer(s_byte) is
					when 1 => s_more <= spi_mosi;  -- bit0 of the byte
					when 2 => s_rlen(7 downto 0) <= unsigned(s_sbuf & spi_mosi);
					when 3 => s_rlen(9) <= s_sbuf(0);
					          s_rlen(8) <= spi_mosi;
					when 4 => s_slen <= unsigned(s_sbuf & spi_mosi);
					          s_cmt_t <= not s_cmt_t;
					when others => null;
					end case;
				elsif s_cmd = x"C5" then
					case to_integer(s_byte) is
					when 1 => s_reu(7 downto 0)   <= s_sbuf & spi_mosi;
					when 2 => s_reu(15 downto 8)  <= s_sbuf & spi_mosi;
					when 3 => s_reu(23 downto 16) <= s_sbuf & spi_mosi;
					when others => null;
					end case;
				end if;
			end if;
		end if;
	end process;

end rtl;
