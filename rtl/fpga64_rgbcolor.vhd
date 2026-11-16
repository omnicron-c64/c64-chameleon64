-- -----------------------------------------------------------------------
--
--                                 FPGA 64
--
--     A fully functional commodore 64 implementation in a single FPGA
--
-- -----------------------------------------------------------------------
-- Copyright 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
-- -----------------------------------------------------------------------
--
-- C64 palette index to 24 bit RGB color
-- 
-- -----------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.all;

-- -----------------------------------------------------------------------
-- Palette RAM: palettes 0-7 built in, palette 8 = custom (loaded .vpl /
-- UCI), initialised to palette 0.  One clock of read latency.
-- -----------------------------------------------------------------------

entity fpga64_rgbcolor is
	port (
		clk: in std_logic;
		palette: in unsigned(3 downto 0);
		index: in unsigned(3 downto 0);
		we: in std_logic := '0';
		windex: in unsigned(3 downto 0) := (others => '0');
		wrgb: in std_logic_vector(23 downto 0) := (others => '0');
		r: out unsigned(7 downto 0);
		g: out unsigned(7 downto 0);
		b: out unsigned(7 downto 0)
	);
end fpga64_rgbcolor;

-- -----------------------------------------------------------------------

architecture Behavioral of fpga64_rgbcolor is
	type pal_t is array(0 to 127) of std_logic_vector(23 downto 0);
	constant BUILTIN : pal_t := (
		x"000000",
		x"ffffff",
		x"813338",
		x"75cec8",
		x"8e3c97",
		x"56ac4d",
		x"2e2c9b",
		x"edf171",
		x"8e5029",
		x"553800",
		x"c46c71",
		x"4a4a4a",
		x"7b7b7b",
		x"a9ff9f",
		x"706deb",
		x"b2b2b2",
		x"000000",
		x"f7f7f7",
		x"8d2f34",
		x"6ad4cd",
		x"9835a4",
		x"4cb442",
		x"2c29b1",
		x"efef5d",
		x"984e20",
		x"5b3800",
		x"d1676d",
		x"4a4a4a",
		x"7b7b7b",
		x"9fef93",
		x"6d6aef",
		x"b2b2b2",
		x"000000",
		x"ffffff",
		x"68372b",
		x"70a4b2",
		x"6f3d86",
		x"588d43",
		x"352879",
		x"b8c76f",
		x"6f4f25",
		x"433900",
		x"9a6759",
		x"444444",
		x"6c6c6c",
		x"9ad284",
		x"6c5eb5",
		x"959595",
		x"000000",
		x"d5d5d5",
		x"72352c",
		x"659fa6",
		x"733a91",
		x"568d35",
		x"2e237d",
		x"aeb75e",
		x"774f1e",
		x"4b3c00",
		x"9c635a",
		x"474747",
		x"6b6b6b",
		x"8fc271",
		x"675db6",
		x"8f8f8f",
		x"000000",
		x"ffffff",
		x"7b1f32",
		x"86dfcd",
		x"b358c2",
		x"49a64b",
		x"3829ad",
		x"c7d555",
		x"b1743a",
		x"533d00",
		x"be6275",
		x"3d3d3d",
		x"808080",
		x"8ce88e",
		x"7b6cf0",
		x"c2c2c2",
		x"000000",
		x"ffffff",
		x"8d3043",
		x"66c0ad",
		x"90359f",
		x"49a64b",
		x"3829ad",
		x"c7d555",
		x"8e5117",
		x"533d00",
		x"be6275",
		x"4e4e4e",
		x"767676",
		x"8ce88e",
		x"7162e6",
		x"a3a3a3",
		x"000000",
		x"ffffff",
		x"8b3436",
		x"65beb9",
		x"8d36a2",
		x"4aa646",
		x"2d30a8",
		x"d2cf57",
		x"8e501b",
		x"543d00",
		x"bc6568",
		x"4e4e4e",
		x"767676",
		x"8de989",
		x"6669e1",
		x"a3a3a3",
		x"000000",
		x"ffffff",
		x"8b3e42",
		x"7cd3cd",
		x"9746a0",
		x"5cb254",
		x"3c39a9",
		x"e3e76e",
		x"945731",
		x"593c07",
		x"cd777c",
		x"505050",
		x"838383",
		x"aff8a6",
		x"7f7df4",
		x"bababa"
	);

	type ram_t is array(0 to 255) of std_logic_vector(23 downto 0);
	function ram_init return ram_t is
		variable v : ram_t := (others => (others => '0'));
	begin
		for i in 0 to 127 loop
			v(i) := BUILTIN(i);
		end loop;
		for i in 0 to 15 loop
			v(128 + i) := BUILTIN(i);
		end loop;
		return v;
	end function;

	signal ram : ram_t := ram_init;
	attribute ramstyle : string;
	attribute ramstyle of ram : signal is "M9K, no_rw_check";
	signal q : std_logic_vector(23 downto 0);
begin
	process(clk)
	begin
		if rising_edge(clk) then
			if we = '1' then
				ram(to_integer("1000" & windex)) <= wrgb;
			end if;
			q <= ram(to_integer(palette & index));
		end if;
	end process;

	r <= unsigned(q(23 downto 16));
	g <= unsigned(q(15 downto 8));
	b <= unsigned(q(7 downto 0));
end Behavioral;
