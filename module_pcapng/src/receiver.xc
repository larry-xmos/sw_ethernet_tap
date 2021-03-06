#include <platform.h>
#include <xscope.h>
#include <stdint.h>
#include <print.h>
#include <xclib.h>

#include "receiver.h"
#include "pcapng.h"
#include "pcapng_conf.h"

static void init_mii_rx(pcapng_mii_rx_t &m)
{
  set_port_use_on(m.p_mii_rxclk);
  m.p_mii_rxclk :> int x;
  set_port_use_on(m.p_mii_rxd);
  set_port_use_on(m.p_mii_rxdv);
  set_pad_delay(m.p_mii_rxclk, PAD_DELAY_RECEIVE);

  set_port_strobed(m.p_mii_rxd);
  set_port_slave(m.p_mii_rxd);

  set_clock_on(m.clk_mii_rx);
  set_clock_src(m.clk_mii_rx, m.p_mii_rxclk);
  set_clock_ready_src(m.clk_mii_rx, m.p_mii_rxdv);
  set_port_clock(m.p_mii_rxd, m.clk_mii_rx);
  set_port_clock(m.p_mii_rxdv, m.clk_mii_rx);

  set_clock_rise_delay(m.clk_mii_rx, CLK_DELAY_RECEIVE);

  start_clock(m.clk_mii_rx);

  clearbuf(m.p_mii_rxd);
}

#define PERIOD_BITS 30

void pcapng_timer_server(streaming chanend c_clients[num_clients], unsigned num_clients)
{
  unsigned t0;
  unsigned next_time;
  timer t;
  unsigned topbits = 0;
  t :> t0;
  next_time = t0 + (1 << PERIOD_BITS);

  while (1) {
    select {
      case c_clients[int i] :> unsigned int time: {
        unsigned int retval = 0;
        if (time - t0 > (1 << PERIOD_BITS))
          retval = (topbits-1) >> (32 - PERIOD_BITS);
        else
          retval = topbits >> (32 - PERIOD_BITS);

        c_clients[i] <: retval;
        break;
      }
      case t when timerafter(next_time) :> void : {
        next_time += (1 << PERIOD_BITS);
        t0 += (1 << PERIOD_BITS);
        topbits++;
        break;
      }
    }
  }
}

#define STW(offset,value) \
  asm volatile("stw %0, %1[%2]"::"r"(value), "r"(dptr), "r"(offset):"memory");

void pcapng_receiver(streaming chanend rx, pcapng_mii_rx_t &mii, streaming chanend c_time_server)
{
  timer t;
  unsigned time;
  unsigned word;
  uintptr_t dptr;

  init_mii_rx(mii);

  set_core_fast_mode_on();

  while (1) {
    unsigned words_rxd = 0;
    unsigned eof = 0;

    // Receive buffer pointer
    rx :> dptr;

    STW(0, PCAPNG_BLOCK_ENHANCED_PACKET); // Block Type
    STW(2, mii.id); // Interface ID

    // If in the middle of the packet then wait for it to end
    int dv = 1;
    while (dv) {
      mii.p_mii_rxdv :> dv;
    }

    // Clear any remaining bytes from the data port
    clearbuf(mii.p_mii_rxd);

    // Wait for the start of frame nibble
    mii.p_mii_rxd when pinseq(0xD) :> int sof;

    // Take start of frame timestamp
    t :> time;
    c_time_server <: time;

    while (!eof) {
      select {
        case mii.p_mii_rxd :> word: {
          // Store the captured words up to the maximum capture length
          if (words_rxd < CAPTURE_WORDS)
            STW(words_rxd + 7, word);
          words_rxd += 1;
          break;
        }
        case mii.p_mii_rxdv when pinseq(0) :> int lo:
        {
          int tail;
          int taillen = endin(mii.p_mii_rxd);

          eof = 1;
          mii.p_mii_rxd :> tail;
          tail = tail >> (32 - taillen);

          // The number of bytes that the packet is in its entirety
          unsigned byte_count = (words_rxd * 4) + (taillen >> 3);
          unsigned packet_len = byte_count;

          if (taillen >> 3) {
            if (words_rxd < CAPTURE_WORDS) {
              STW(words_rxd + 7, tail);
              words_rxd += 1;
            }
          }

          if (byte_count > CAPTURE_BYTES) {
            byte_count = CAPTURE_BYTES;
            words_rxd = CAPTURE_WORDS;
          }

          unsigned int total_length = (words_rxd * 4) + PCAPNG_EPB_OVERHEAD_BYTES;
          STW(1, total_length);              // Block Total Length
          STW(5, byte_count);                // Captured Len
          STW(6, packet_len);                // Packet Len
          STW(words_rxd + 7, total_length);  // Block Total Length

          // Do this once packet reception is finished
          STW(4, time); // TimeStamp Low
          unsigned time_top_bits = 0;
          c_time_server :> time_top_bits;
          STW(3, time_top_bits); // TimeStamp High

          rx <: dptr;
          rx <: total_length;

          break;
        }
      }
    }
  }
}

