-- -----------------------------------------------------------------------
-- UCI register front end ($DF1C-$DF1F) + custom palette loader
--
-- UCI registers (only when uci_enable = '1'):
--   $DF1C W: control  bit0 PUSH_CMD, bit1 DATA_ACC, bit2 ABORT, bit3 CLR_ERR
--         R: status   bit7 DATA_AV, bit6 STAT_AV, bit5-4 STATE, bit3 ERROR
--   $DF1D W: command byte          R: identification $C9
--   $DF1E R: response data (none yet, reads $00)
--   $DF1F R: status string ("00,OK" / "21,NOT SUPPORTED")
--
-- Core-local command target $F0 (palette):
--   F0 01 idx R G B      set custom palette color idx, select custom palette
--   F0 02 R G B x 16     set whole custom palette, select custom palette
--   F0 03 n              select palette n (0-7 built-in, 8 custom)
-- Every other target/command answers "21,NOT SUPPORTED".
--
-- .vpl (VICE palette) text files are decoded as they are downloaded:
-- '#' starts a comment, each other line holds "RR GG BB [dither]" in hex.
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
	pal_rgb      : out std_logic_vector(23 downto 0)
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

	-- bus
	signal cs        : std_logic;
	signal phi_d     : std_logic;
	signal cs_d      : std_logic;
	signal rnw_d     : std_logic;
	signal a_d       : std_logic_vector(1 downto 0);
	signal din_d     : std_logic_vector(7 downto 0);

	-- UCI state
	signal state     : std_logic_vector(1 downto 0);
	signal err       : std_logic;
	signal stat_av   : std_logic;
	signal msg_sel   : std_logic;
	signal msg_ptr   : unsigned(4 downto 0);
	signal stat_byte : std_logic_vector(7 downto 0);
	signal cnt       : unsigned(5 downto 0);
	signal target    : std_logic_vector(7 downto 0);
	signal cmd       : std_logic_vector(7 downto 0);
	signal arg0      : std_logic_vector(7 downto 0);
	signal u_r, u_g  : std_logic_vector(7 downto 0);
	signal comp      : unsigned(1 downto 0);
	signal col       : unsigned(4 downto 0);

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

	cs <= '1' when uci_enable = '1' and phi = '1' and iof = '1' and addr(7 downto 2) = "000111" else '0';
	oe <= cs and rnw;

	stat_byte <= msg_byte(msg_sel, msg_ptr) when stat_av = '1' else x"00";

	with addr(1 downto 0) select dout <=
		'0' & stat_av & state & err & "000" when "00",
		x"C9"                               when "01",
		x"00"                               when "10",
		stat_byte                           when others;

	palette_sel <= sel_reg;

	process(clk)
		variable h : integer;
		variable eol, tok_end : boolean;
		variable ok : boolean;
	begin
		if rising_edge(clk) then
			pal_we <= '0';

			-- menu palette choice always wins when it changes
			menu_d <= menu_palette;
			if menu_palette /= menu_d then
				sel_reg <= '0' & menu_palette;
			end if;

			------------------------------------------------------------------
			-- UCI bus access, acted on at the end of phi2
			------------------------------------------------------------------
			phi_d <= phi;
			if cs = '1' then
				cs_d  <= '1';
				rnw_d <= rnw;
				a_d   <= addr(1 downto 0);
				din_d <= din;
			end if;

			if phi = '0' and phi_d = '1' then
				cs_d <= '0';
			end if;

			if reset = '1' then
				state   <= "00";
				err     <= '0';
				stat_av <= '0';
				cnt     <= (others => '0');
				cs_d    <= '0';
			elsif phi = '0' and phi_d = '1' and cs_d = '1' then
				if rnw_d = '0' then
					case a_d is
					when "00" =>
						if din_d(3) = '1' then
							err <= '0';
						end if;
						if din_d(2) = '1' then              -- abort
							state <= "00"; stat_av <= '0'; cnt <= (others => '0');
						elsif din_d(1) = '1' then           -- data accepted
							if state /= "00" then
								state <= "00"; stat_av <= '0'; cnt <= (others => '0');
							end if;
						elsif din_d(0) = '1' then           -- push command
							if state = "00" then
								ok := target = x"F0" and
								      ((cmd = x"01" and cnt >= 6) or
								       (cmd = x"02" and cnt >= 5) or
								       (cmd = x"03" and cnt >= 3 and unsigned(arg0) <= 8));
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
								state   <= "10";
								stat_av <= '1';
								msg_ptr <= (others => '0');
								cnt     <= (others => '0');
							else
								err <= '1';
							end if;
						end if;

					when "01" =>                            -- command byte
						if state /= "00" then
							err <= '1';
						else
							if cnt /= 63 then
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
					if a_d = "11" and stat_av = '1' then    -- status string pop
						if (msg_sel = '0' and msg_ptr = MSG_OK'length-1) or
						   (msg_sel = '1' and msg_ptr = MSG_ERR'length-1) then
							stat_av <= '0';
						end if;
						msg_ptr <= msg_ptr + 1;
					end if;
				end if;
			end if;

			if uci_enable = '0' then
				state   <= "00";
				stat_av <= '0';
				cnt     <= (others => '0');
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
				if vpl_download = '0' then          -- end of file: flush last line
					eol := true;
					tok_end := true;
				elsif vp_comment = '1' then
					if vpl_data = x"0A" or vpl_data = x"0D" then
						vp_comment <= '0';
						eol := true;
					end if;
				elsif vpl_data = x"23" then          -- '#'
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

end rtl;
