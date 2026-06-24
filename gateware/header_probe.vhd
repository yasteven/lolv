library ieee;
use ieee.std_logic_1164.all;

entity header_probe is
  port (
    clk       : in    std_logic;
    rst       : in    std_logic;

    enable    : in    std_logic;
    oe        : in    std_logic_vector(11 downto 0);
    out_value : in    std_logic_vector(11 downto 0);
    in_value  : out   std_logic_vector(11 downto 0);

    gpio      : inout std_logic_vector(11 downto 0)
  );
end entity header_probe;

architecture rtl of header_probe is
begin
  gen_gpio : for i in 0 to 11 generate
  begin
    gpio(i) <= out_value(i) when enable = '1' and oe(i) = '1' else 'Z';
    in_value(i) <= gpio(i);
  end generate;
end architecture rtl;
