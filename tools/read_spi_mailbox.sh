#!/usr/bin/env sh
set -eu

read_reg() {
    name="$1"
    addr="$2"
    printf '%-20s ' "$name"
    devmem "$addr" 32
}

case "${1:-read}" in
    clear)
        devmem 0xf0005014 32 0x00000002
        ;;
    ack)
        devmem 0xf0005014 32 0x00000001
        ;;
    read)
        read_reg rx_data           0xf0005000
        read_reg tx_data           0xf0005004
        read_reg rx_length         0xf0005008
        read_reg status            0xf000500c
        read_reg transaction_count 0xf0005010
        read_reg raw_mosi          0xf0005018
        read_reg raw_length        0xf000501c
        read_reg raw_done          0xf0005020
        read_reg raw_pins          0xf0005024
        ;;
    *)
        echo "usage: $0 [read|clear|ack]" >&2
        exit 2
        ;;
esac
