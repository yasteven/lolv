#!/usr/bin/env sh
set -eu

TX_DATA=0xf0005004
CONTROL=0xf0005014
pattern="${1:-0xA55A3CC3}"

echo "OrangeCrab SPI MISO preparation"
echo "pattern: $pattern"

devmem "$CONTROL" 32 0x00000002
devmem "$TX_DATA" 32 "$pattern"

printf "%-30s " "tx_data_readback"
devmem "$TX_DATA" 32

echo
echo "Run on Jetson:"
echo "  ./tools/spi_miso_jetson.sh $pattern"
echo
echo "Then press Enter here."
read _

for x in     "rx_data:0xf0005000"     "tx_data:0xf0005004"     "rx_length:0xf0005008"     "status:0xf000500c"     "transaction_count:0xf0005010"     "raw_mosi:0xf0005018"     "raw_length:0xf000501c"     "raw_done:0xf0005020"     "raw_pins:0xf0005024"     "raw_cs_assert_count:0xf0005028"     "raw_cs_deassert_count:0xf000502c"     "raw_sck_rise_count:0xf0005030"     "raw_sck_fall_count:0xf0005034"     "raw_mosi_high_on_sck_rise:0xf0005038"     "raw_mosi_low_on_sck_rise:0xf000503c"
do
    name="${x%%:*}"
    addr="${x##*:}"
    printf "%-30s " "$name"
    devmem "$addr" 32
done
