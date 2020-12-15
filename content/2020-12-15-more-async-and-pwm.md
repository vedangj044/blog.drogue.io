+++
title = "More Rust & Async (and hand-rolled PWM)"
description = "Improvements to an async embedded kernel for Rust"
extra.author = "bobmcwhirter"
+++

If we start living the async lifestyle, we can potentially get more
use out of our limited hardware resources.  Maybe not, but it's worth
exploring. Let's explore.

<!-- more -->

# Embedded, RTOS, OSes and Frameworks

First, let's all agree we're doing embedded work on bare chips, where we
can pretty freely twiddle any register we want. In the Rust world, this
would be called *bare metal* development.

Take a step upwards, and you've got a framework such as RTIC, which provides
facilities to make writing functional embedded code easier, while also
making it easier to organize your code and reason over it.

A step beyond that would be something like Zephyr, Tock, Drone or another
RTOS (real-time operating system). RTOSes can be further differentiated into
"hard" real-time (hey, airbag needs to absolutely fire within 15 nano-seconds
of impact) or "soft" real-time, which relaxes the timing requirements.

Beyond that, you get to a more general-purpose OS, which may or may not
include things like network drivers and other facilities we've come to
love on our machines running BeOS or OS/2 Warp (or, I guess, Linux).

In general, all of the above, from an embedded point-of-view, provide basically:

* Ways to run tasks
* Ways to handle interrupts
* Misc useful capabilities used by the above

## An `async` opportunity

I have to admit I'm smitten with `async` and `await` on Rust. It just works
the way my mind does. I also have to admit that I've repeated told my boss
"no, dude, we're not writing an RTOS" (Hi, Mark). Then again, I also must admit that my
employer tends to write tools and frameworks for application developers, along
with OSes, so I don't think I'm coloring too far outside the lines in exploring
an async-centric embedded kernel.

Instead of trying to make Linux (or something that feels Linux-like) fit onto
a small board, what if we built an "OS" (but we're not calling it that) from 
the foundations based upon a modern and safe language (Rust) using modern and
efficient idioms (async/reactive)?

But let's just call it a _framework_.

# What would it look like?

This week, it looks like the following:

## Ways to run tasks

We touched on this in the [last blog post](/rust-and-async/) I wrote, but it's simply `spawn`ing
async Rust tasks, probably containing a loop.

```rust
Kernel::spawn("ld2", async move {
    loop {
        // do awesome stuff
    }
});
```

## Ways to handle interrupts

Here we venture somewhat outside of the "real-time" aspect of RTOSes, which I think
is okay, depending on your use-case. Some operating systems attempt to limit the
work you actually do within an ISR (interrupt service routine), and rather use an
interrupt to wake up a normal "user-land" task that is blocked waiting for its
interrupt to fire.

In my current sketching, I have an API that takes a _non async closure_, but behind
the scenes wraps it in an async task with a _wait for my interrupt_ and a loop.

### The visible API

```rust
Kernel::interrupt(EXTI15_10, move || {
    if pc13.check_interrupt() {
        if pc13.is_low().unwrap() {
            log::info!("button pushed");
        } else {
            log::info!("button released");
        }
        pc13.clear_interrupt_pending_bit();
    }
});
```

### The internal magic

It uses the same `Kernel::spawn(...)` as non-interrupt tasks, along with my
`async`-capable `interrupt(...)` API which provides a `Future` which satisfies
when the associated IRQ is pending.

Then it just calls the passed in closure.

```rust
    pub fn interrupt<N: Nr + Debug + Copy + 'static, F>(irq: N, mut isr: F) -> Result<(), SpawnError>
        where F: FnMut() -> () + 'static,
    {
        let mut name = String::<U16>::new();
        write!(name, "{:?}", irq);
        Self::spawn(name.as_str(), async move {
            loop {
                interrupt::interrupt(irq).await;
                isr();
            }
        }).map(|_| ())
    }
```

# Using the Resources and Organizing Code

My example application running on this board uses a single timer to make two LEDs
"breathe" in a non-synchronized manner. You can absolutely re-create this without
using `async` tasks, but you will be managing a shared interrupt across two _users_
of that interrupt (the LEDs themselves).

This is a very contrived example of using a timer to manually create a poor-man's
PWM output, but it seemed like a useful challenge to attempt.

## Quick Aside: PWM

PWM stands for Pulse-Wave Modulation, which in this case means taking a thing that
is either strictly *on* or *off* (the LED), and flipping it on and off fast enough 
to appear that it's at 0 to 100% brightness, on a continuum. The human eye will see
an LED that is on 50% of the time and off 50% of the time as about half as bright
as a fully-on LED. If we flip the switch fast enough, it looks "dim", and not flickery.
(Which, coincidently is why slo-mo video under LEDs looks very blinky blinky).

### </End of Aside>

Since we're talking about flipping an LED on/off on some sort of regular schedule,
that's where the timer is involved. Managing one timer and one LED is "easy" for small
values of "easy", but using a single timer for multiple LEDs could be more of a challenge
if you're directly handling the timer's _timeout_ interrupts. So you might be tempted
to use a timer per LED. Until you run out of timers.

With `async`, we can quite easily manage multiple LEDs from a single timer. With
my exploratory kernel, we don't have to think about interrupts, but rather only
tasks.

Don't judge my math, but basically we spawn two tasks that look identical (modulo
an initial delay), which runs a `duty_cycle` from 1 to 99 and back, repeatedly.

At each step, the LED is on for roughly `duty_cycle` microseconds, and off for `100 - duty_cycle`
microseconds. For visual appearances, each time is multiplied by `20` in this case,
and we linger on each step for 4 iterations of a loop. Then we adjust `duty_cycle`
and do it again, turning around when we reach 99 or 1, back and forth, back and forth.

```rust
    Kernel::spawn("ld2", async move {
        let mut duty_cycle = 1;
        let mut up = true;
        let dwell = 4;
        let mult = 20;

	// the other task does not have this initial 1sec delay
        AsyncTimer::delay_ms( Milliseconds(1000u32)).await;

        loop {
            for _ in 0..dwell {
                let on: u32 = (duty_cycle * mult) as u32;
                let off: u32 = ((100 - duty_cycle) * mult) as u32;
                ld2.set_high().unwrap();
                AsyncTimer::delay_us(Microseconds(on)).await;
                ld2.set_low().unwrap();
                AsyncTimer::delay_us(Microseconds(off)).await;
            }

            if duty_cycle == 99 {
                up = false
            } else if duty_cycle == 1 {
                up = true;
            }

            if up {
                duty_cycle += 1
            } else {
                duty_cycle -= 1;
            }
        }
    });
```

{{ vimeo(id="491304511") }}

As many tasks as we like can conceivably use the singular `AsyncTimer` which
is currently linked to exactly one timer (`TIM15` here). Each task
only has to focus on the logic of waiting, turning on, waiting, turning off,
and can ignore the fact that `TIM15` interrupts are firing.

# Conclusion

I like where this is going. I think the next steps might be to help isolate
a task's state into an _actor_ framework using `async`, and providing a
message-passing way for them to safely communicate.

Plus, I got to try out my new desktop tripod for phone videos. So that's a win.
