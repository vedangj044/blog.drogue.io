+++
title = "It's a Matter of Time"
extra.author = "bobmcwhirter"
+++

In the embedded world, quite often you don't have a _wall clock_ sort of clock. 
You may have something that can reckon the passage of time, though. 
The various current solutions for managing time within embedded Rust has yet to be completely abstracted.
We leverage some up-and-coming libraries to help paper over the differences.

<!-- more -->

# Time keeps on slipping... into the future...

When you're doing embedded Rust, sometimes you want to know how much time has passed, and sometimes you want to _pause_ for some amount of time.

The `embedded-hal` provides two useful types of traits:

* Delays
* Timers

A *delay* provides a blocking operation which pauses execution for some amount of time.
A *timer* allows you to know when some amount of time has elapsed.

At least using my [current board](https://www.st.com/en/evaluation-tools/b-l4s5i-iot01a.html), based on the STM32L4 family, the HAL provides exactly 1 delay, but a large handful of timers.

Why is this important?

I'm trying to interface over [SPI](https://en.wikipedia.org/wiki/Serial_Peripheral_Interface) to yet-another WiFi-offload board.

This board, like many, needs certain pins raised and lowered. 
It also needs you to wait a few milliseconds after raising or lowering the pin before you assume the board has dealt with the change.

Roughly:

1. Lower pin, signalling you are about to send some data.
2. Wait 10 milliseconds.
3. Send some data.
4. Raise the pin signalling you are done sending data.

# One Delay, Multiple Timers

As noted, often you might find yourself in an environment that only has one available Delay.
And if your environment is RTIC, the framework itself may take the delay facilities for its own software task scheduling, leaving you with zero.
Add to that multiple drivers that need to be able to delay every now and then, and you find yourself in a precarious situation.

# No unified concept of _time_

The various HALs may define their own time structures, their timers might work in terms of milliseconds or hertz, and in general
it's quite difficult to write any device driver that can have assurances of how time is managed and recorded.

# Enter `embedded-time` and `drogue-embedded-timer`

## `embedded-time`

Peter Taylor has been trying to create a unified view of time for the embedded world, suitable called [`embedded-time`](https://crates.io/crates/embedded-time).
It provides everything you could hope for in terms of units-of-time, duration and instance measurements, and conversions into/from rates.
It does _not_ provide bindings to hardware.

## `drogue-embedded-timer`

The [`drogue-embedded-timer`](https://crates.io/crates/drogue-embedded-timer) library attempts to provide directly-usable bindings of
Peter's `embedded-time` library to the embedded Rust HAL-centric world.

## Clocks

At the bottom of the stack is an `embedded-time` `Clock`, which is a software device to measure the passage of time.
It may have an arbitrary amount of precision, marking off individual microseconds, dozens of milliseconds, or entire seconds at each _tick_.

## Timers (and Delays)

Once you have a clock that you can watch, you can then define a `Timer` which is capable of measuring some specific duration of time, according to that clock.
If you make that timer pause until the duration of time has passed, you have yourself a `Delay`.

# Build the `Clock`

As noted above, the clock can have whatever precision makes sense in your application. 
If you need millisecond precision, you tick the clock every 1 millisecond.
If you need less precision, maybe you tick it every 500 milliseconds, saving yourself some power along the way.
If you have the need for _multiple_ different precision clocks (one ticking microseconds while another ticks away seconds), that's also quite possible.

Creating the clock is as easy as defining a static `Clock` of the precision you need.

The `drogue-embedded-timer` library has a variety of different clocks set up for a variety of different precisions.
Let's use a clock with 100ms precision:

```rust
use drogue_embedded_timer::MillisecondsClock100;

static CLOCK: MillisecondsClock100 = MillisecondsClock100::new();
```

# Make the `Clock` tick.

Okay, we have a clock, but it's just sitting there, frozen in time.
Thankfully, the clock can provide an external remote-control that will tick it forward (100ms in this case) every time you push the button.
The easiest way to push the button on a regular basis is using your HAL's _timers_ and their associated interrupts.

So on my board, the first thing I do is use `TIM15` and set it up to timeout every 100ms, so that it has a known rhythm that matches my `CLOCK` defined above:

```rust
let mut tim15 = Timer::tim15(device.TIM15, 100, clocks, &mut rcc.apb2);
```

I enable the interrupt so that it fires ever time the timeout occurs, giving me a chance to push the button and advance my `CLOCK` ahead one 100ms tick:

```rust
tim15.listen(Event::TimeOut);
```

Since each HAL does things possibly differently, but we know an interrupt must be cleared once it's handled, you're able to provide a callback that will be executed for each tick, to give you a chance to do just that.
The callback is actually in the form of an opaque object (usually your TIM* timer object), and a closure that can use that object.

On my current board, I'm using the `TIM15` timer, and I have to call `timer.clear_interrupt(Event::TimeOut)` each time the ISR is invoked.

Therefore, we need to pass that information to the `CLOCK` when we ask to get the ticker for it:

```rust
let ticker = CLOCK.ticker(tim15, 
                          (|t| { t.clear_interrupt(Event::TimeOut); }) as fn(&mut Timer<TIM15>));
```

All that's left now is to actually wire up the interrupt handler to the `TIM15` interrupt.
Using RTIC, I bind a task to it. I've also put the `ticker` into the shared resources so my ISR can access it.

```rust
init::LateResources {
    ticker,
    ...
}
```

```rust
#[task(binds = TIM15, priority = 15, resources = [ticker])]
fn ticker(mut ctx: ticker::Context) {
    ctx.resources.ticker.tick();
}
```

I make sure the priority of this ISR is pretty high, because I don't want my clock to slow down if the system is also under load doing other thing.

At this point, _time is flowing forward_.

# Timers & Delays

Now the `CLOCK` static is a bonafide `embedded-time` `Clock` implementation, and can do all the things Peter's APIs allow you to do.

You can create an `embedded-time` `Timer` and use it however you like:

```rust
// Create a 10 second timer
let timer = embedded_time::Timer::new(&CLOCK, Seconds(10u32));

// Start the timer
let timer = timer.start().unwrap();

// Wait for 10 seconds to expire (blocking)
timer.wait().unwrap();
```

Our use-case from the very top of this article, though, is being able to block for a little while.
The `embedded-hal` provide two blocking `Delay` implementations.
`drogue-embedded-timer` doesn't rely on `embedded-hal` so we provide an alternative `Delay` implementation, which is `embedded-time`-native.

```rust
// Construct a new Delay
let mut delay = CLOCK.delay();

// Delay for 4 seconds (blocking)
delay.delay(Seconds(4u32));

// Delay for 4000 milliseconds (blocking)
delay.delay(Milliseconds(4000u32));
```

One thing to keep in mind is that your delay will always be at least as long as the precision of your clock.
Since we created a clock with 100 milliseconds of precision (1/10th of a second), our delay can be _no shorter than that_.
Math also tells us our delay could end up being a hair less than _twice_ the precision, depending on how long you're attempting to delay.
It's wise to ensure the precision is half the time of your average delay.
For instance, if you want to delay for 10 milliseconds, you should probably create a clock with a 5 millisecond precision.

# Conclusion

With a unified and abstracted way to consider time, timers and delays, device-drivers that need to understand time can be written more generically.
It also means less shimming of your board-specific timers into whatever format your driver might want.
