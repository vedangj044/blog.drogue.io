+++
title = "Rust Embedded Layer Cake"
+++

# Rust, Embedded

As noted in the first post, I'm working towards doing more IoT using Rust
in an embedded ARM Cortex-M world.  Thankfully, the Rust compiler leverages
LLVM and can target quite a few different processors. 

# Instruction Sets & Processors

That being said, there are _quite a few different processors_ even within the 
Cortex-M family.  They all have mostly similar instruction sets, which makes 
the generation of the executable pretty straightforward (for the compiler).

But each processor contains different amounts of flash memory (where the 
program is stored) and different amounts of RAM (used during the execution
of the program).

The ARM processors are different than you might have experienced with the
Intel and AMD processors, because ARM is _licensed intellectual property_
where a multitude of manufacturers can create their own processor, mostly
following ARM's specifications. 

# Peripherals

One of the largest sources of variety is in the _peripherals_ within the
processor. With desktop machines, we think of peripherals as "a display"
or "an external harddrive" or "a mouse". Within an embedded processor,
a perhipheral is lower-level, embodying things like *timers* and *SPI* busses
and *serial port thingies*.

Each of these peripherals is interacted with by code through one or more
_registers_, which is a byte (or two or four) of memory within the processor.
These registers get _memory mapped_ into the normal RAM-addressable memory
that code can operate upon.

For instance, within the STM32F401 processor from STMicroelectronics,
there are a few registers for configuring and interacting with the USART
(a "serial port"). Some bits of the registers control the baud rate, stop-bits,
and parity of the underlying serial bus. Other registers are used to transfer
octets from your code to the serial bus and to receive octets from the serial bus
into your code. Additional registers are used to communicate if errors have 
occurred while attempting to move data across (overruns, parity errors, noise).

The reference manuals for process describe the memory location and semantics
of each bit/byte of each register for each peripheral. 

![USART registers](/images/usart-regs.png)

Working with memory addresses and bitwise manipulation of these registers
would be... challenging.

# Peripheral Access Crates (PAC)

Thankfully, each producer of ARM Cortex-M chips also ship a related XML files
called an SVD (System View Descriptor). These files take the prose information
from the reference manuals and makes it machine-readable. Tooling in the Rust
community, called [svd2rust](https://crates.io/crates/svd2rust) can consume
these files and produce Rust code so we can use friendly name to manipulate registers.
The result of using `svd2rust` is what's called a _peripheral access crate_, or _PAC_.

One example is the [stm32f4](https://crates.io/crates/stm32f4) crate.

Once you have a PAC, you can at least write slightly better-looking code, but
you are still _thinking_ in terms of registers, bits and bytes. A PAC doesn't quite
get you up to the semantics of _a serial port thingy_.

# Hardware Abstraction Layer (HAL)

While different silicon manufacturers produce similar but different ARM Cortex-M
chips, using possibly different registers to accomplish things, at the end of the day,
many still have _serial port thingies_ (e.g. a USART).

To begin to bring commonality across the chips, there's a _hardware abstraction layer (HAL)_.
The HAL is created in two parts. First is the common [embedded-hal](https://docs.rs/embedded-hal)
which defines abstractions such as how to [_read_ or _write_ to a serial port](https://docs.rs/embedded-hal/0.2.4/embedded_hal/serial/index.html).
Note, it does not define an abstraction for _serial port_ itself, since the configuration
and setup of a serial port is still quite chip-specific. But assuming you've configured
a port, `embedded-hal` gives us a common way to read octets or write octets (or words,
or whatever size data the specific port supports).

The `embedded-hal` is purely a crate of Rust _traits_, and by itself is not functional.

Humans create a _HAL implementation_ for a specific bit of silicon using the
generated _PAC_ in order to provide a friendly way of interacting with different chips.

For instance, there's the [stm32f4xx](https://docs.rs/embedded-hal/0.2.4/embedded_hal/serial/index.html)
HAL crate which has been lovingly hand-crafted, using the [stm32f PAC](https://crates.io/crates/stm32f4)
in order to safely configure and use a chip from the STM32F4 family of silicon.

The HAL includes plenty of bits that don't map to the `embedded-hal` traits, because
activities such as setting up the serial port thingy is outside of scope for `embedded-hal`,
but it also does mix in the `embedded-hal` traits where the functionality overlaps.

# Safety

One benefit Rust HALs have over other HALs based on other languages is the safety
that can be provided using _zero cost abstractions_.

Take, for instance, on the STM32F401 chip, one of the serial port thingies (USART6) 
can be connected to a couple of different sets of pins. Since each chip tends to ultimately
have more peripherals than can be surfaces through physical pins, a lot of pins can
perform one of several functions. 

In the case of USART6, the transmission line can be attached to pin `PA11` or `PC6`.
`PC6` could alternatively be configured for usage with `i2c` or `SDIO`. Until you
explicitly configure the pin for usage as the USART6 transmission line, the HAL
will _not_ allow you to use it to further configure the USART6 serial port thingy.

In my case, I've wired up my serial port device to pins `PA11` for transmission (tx)
and `PA12` for receiving (rx).

First I get the `PAC` representation of the GPIO pins, the little bits of metal sticking
out of my board:

```rust
let gpioa = device.GPIOA.split();
```

Then I select off the two pins I need for my USART:

```rust
let pa11 = gpioa.pa11;
let pa12 = gpioa.pa12;
```

At this point, `pa11` and `pa12` are of type `PA11<Input<Floating>>` and
`PA12<Input<Floating>>` respectively. Two floating digital input pins is
*not* sufficient for usage as a serial point.


So next, I configure the processor to know I want to use them for USART6 instead 
of any of the other usages they could have. The `into_alternative_af8()` is 
how I tell the processor (through the PAC) that I intend to use them as USART6:

```rust
let tx_pin = gpioa.pa11.into_alternate_af8();
let rx_pin = gpioa.pa12.into_alternate_af8();
```

Now, the types of `tx_pin` and `rx_pin` are `PA11<Alternate<AF8>>` and
`<PA12<Alternate<AF8>>` respectively. I can't use them a simple digital I/O
pins now, because Rust has consumed the generic pins and returned me USART-configured
pins.

I can finally use the HAL method to configure my serial port thingy:

```rust
let mut serial = Serial::usart6(
            usart6,
            (tx_pin, rx_pin),
            ... 
            ...);
```

The `usart6(...)` function will *only* accept appropriate configured pins which
are usable as USART6. The compiler will not let me use arbitrary pins, or even
correct pins that haven't been fully configured.

Now, though, our `serial` implements the `Read<...>` and `Write<...>` traits
from `embedded-hal` and can be handed off to an actual device driver that
is written purely from the point-of-view of `embedded-hal`. 

The device driver doesn't need to know which vendors silicon I'm using, just that
there's now an object that can be written to and read from.

# Finally...

Embedded coding is hard, especially when you're not stupendously experienced doing it.
On the other hand, using Rust provides a nice set of abstractions and a _ton_ of guardrails
to prevent you from flying off the cliff of correct code.

