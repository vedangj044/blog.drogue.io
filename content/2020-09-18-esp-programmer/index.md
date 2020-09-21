+++
title = "Creating an ESP programmer"
extra.author = "ctron"
+++

Getting started with an [ESP-01](https://en.wikipedia.org/wiki/ESP8266#Pinout_of_ESP-01) isn't one of the easiest
things. At least if you are not used to embedded systems. It is a nice solution though to add Wi-Fi
capabilities to an existing platform.

<!-- more -->

# The ESP-01

I started out with my [STM32F723E-DISCOVERY](https://www.st.com/en/evaluation-tools/32f723ediscovery.html) board,
and choose it simply because it provides a nice set of interfaces. Which is great for testing and, well, discovering.

What it doesn't have, is on-board Wi-Fi, or any other kind of network support. Not ideal if you plan on doing IoT.

However, brings a ready-to-plug ESP-01 port, which is mapped to an internal UART. That port is specifically designed
for the ESP-01. It has a matching slot, with the correct pin assignment, the required 3.3V, and maps to UART5 on the
board.

<figure>
<picture>
    <source type="image/webp" srcset="esp.webp">
    <img style="max-width: 900px" class="ignore-js" src="esp.jpg" alt="ESP-01 on STM32F723E-DISCOVERY">
</picture>
</figure>

My naive idea, was to simply plug it in, and "dial out" to the internet with some
[AT commands](https://www.espressif.com/sites/default/files/documentation/4a-esp8266_at_instruction_set_en.pdf). The
ESP chips provide an out-of-the-box firmware, which offers you a set of "AT commands", that control the Wi-Fi and
TCP/IP stack, which is embedded in the chip. You only need some serial communication, and let the chip handle the more
complex things.

# Firmware updates

Before ordering, I already read that the shipped firmware of some ESPs, is most likely extremely old. And indeed,
that was the case for me as well. I had hoped for something more recent, but I had no luck.

Playing with some NodeMCU like boards, which feature the same ESP8622 chip, I know that you can easily flash a new
firmware using the `esptool.py` from the command line. All you need is a PC and a USB cable. The problem is, the ESP-01
doesn't have a USB port. In the case of the NodeMCU, you have an UART interface built into the board, which connects
the USB port with the ESP. On the USB host, you simply see it as a UART USB interface.

As the ESP-01 requires 3.3V, instead of the 5V that most other UARTs require, you do need to come up with [some extra
wiring](https://www.iot-experiments.com/flashing-esp8266-esp01/#onperfboard). There are a lot of tutorials on the net,
which explain how to flash an ESP-01. I guess, the simplest solution is to buy and FTDI adapter, which supports 3.3V.
However, even that still requires you to come up with a solution for triggering the programming mode of the ESP via
the GPIO0 port.

# The solution

On the other side, right on my desk was the discovery board, which has support for the ESP-01 out of the box. It also
has an internal "virtual com port", which is connected through USB with the host over the ST-LINK port. On the board it
is known as `USART6`, and on my Linux machine, it becomes `/dev/ttyACM0`.

The only thing required was a "proxy", which bridges the two serial ports. A few lines of Rust later, I came up with
a rather simple loop, which looked something like this:

~~~rust
loop {
   if let Ok(c) = rx_esp.read() {
      to_vcom.push(c);
   }
   if let Ok(c) = rx_vcom.read() {
      to_esp.push(c);
   }
   if let Some(to_esp.peek()) {
      if let Ok(_) = tx_esp.write() {
         to_esp.poll();
      }
   }
   if let Some(to_vcom.peek()) {
      if let Ok(_) = tx_vcom.write() {
         tx_vcom.poll();
      }
   }
}
~~~

To be fair, my code doesn't look as elegant as this. You can take a peek at
[ctron/embedded-serial-bridge](https://github.com/ctron/embedded-serial-bridge). However, it isn't too difficult either.
I think Rust helps you a lot to write readable code, even in the context of embedded devices. 

Plugging in the discovery board now provides a USB serial interface. Depending on the mode I select, the ESP gets
booted either in *normal mode* or in *programming mode*. In the programming mode, I can use the `esptool` now to
flash the ESP-01. Or recover from a bricked device. In normal mode, I can use [minicom](https://en.wikipedia.org/wiki/Minicom),
to play with AT commands. 

# Lessons learned

Was that really necessary? It was a good opportunity to learn about embedded and Rust. As mentioned before, I could
have bought an FTDI adapter, and try to get away with that. On the other side, building that serial bridge with Rust
and [`cargo embed`](https://github.com/probe-rs/cargo-embed), was quite easy.

A problem that I faced during development, was that I lost quite a number of characters at some point.
My assumption was, that although I did not use DMA and interrupts, the loop should be fast enough to
process a few characters.

It took me a while until I figured out, that this was caused by the Rust debug code. The more complex my program got,
the more characters I did loose. Building in release mode with `cargo embed --release` fixed the issue.

# Future improvements

My itch is scratched. On the other side, I am pretty sure I will need to flash some ESP-01 in the future. So maybe
I will make my own life easier and make use of the *user button* that the ESP has. It could be used top reset the ESP
after flashing. Or switch the modes between programming and normal mode. The LEDs could be use, to show serial traffic,
or in which mode the system is.

It could also be fun, to port this to a different board. Right now the code is specifically written for the STM32F723IE.
The Rust build support *features*, which allow you to do conditional compilation and dependencies. The good thing
with Rust's conditional compilation is, that all the guarantees that Rust gives, you are still valid. So it should
be possible to allow you to compile for a specific board, like this:

~~~
cargo embed --feature <your board>
~~~

And maybe, if you have the some problem, this gives you a reason to try it out yourself.

# See also 

* GitHub repository &mdash; https://github.com/ctron/embedded-serial-bridge
* Cargo embed &mdash; https://github.com/probe-rs/cargo-embed
* Rust/Cargo Features &mdash; https://doc.rust-lang.org/cargo/reference/features.html
