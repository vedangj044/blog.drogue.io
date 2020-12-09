+++
title = "Rust and Async (on embedded devices)"
description = "async/await is available for embedded devices, let's explore"
extra.author = "bobmcwhirter"
+++

`async`/`await` within Rust is a convenient way to gain parallelism,
even on an embedded device where we ostensibly have exactly one userland
thread by default.

<!-- more -->

# Threads and `async`/`await`

## First, threads...

While living the larger laptop/server CPU lifestyle, we've grown acustomed
to having threads. Lots of threads. Each thread generally provides the illusion
of a straight-line execution of code that owns the entire processor. 
As some books describe it, from the thread's point-of-view, the whole processor
is theirs, just sometimes (while other threads are running), it's just a very
slow processor.

To accomplish this magic of appearing to own the entire processor, threads
also have to actually give each thread it's own space for it's stack 
to grow. Additionally, the kernel has to occasionally freeze one thread, swap
out that thread's stack for another waiting thread's, and then unfreeze the other 
thread to run for a bit. This is _context switching_.

The same thing happens when running multiple processes instead of just threads,
but then the heap and the memory-manager gets involved, so that each process has
its own supposedly unlimited memory address space.

This is all great (aside from race conditions), but also quite heavy for achieving
parallelism on a small $2 MCU that is already running its tail off to blink some LEDs
in a timely manner.

## Now, async...

With Rust (and several other languages), there's the idea of `async` and `await`,
which ultimately represent a way to deal with _cooperative_ multi-tasking, instead
of _preemptive_ as defined by modern threads and processes.

To live the `async` lifestyle with Rust, you first must mark your function or method as
`async`. Unfortunately, you can now no longer call this method from code that isn't 
also async. And simply marking your function as `async` really accomplishes very little.

But once you're in an async context (getting into one, we'll address shortly), you can 
call other async functions, and here's where the magic happens. Calling an async function 
will not return the result you're asking for. Great? Great! Instead, it signals you'd like 
that function to go off, and do whatever it needs to do, and you'll check back later when 
you need to know the answer.

```
async fn foo() {
  let not_the_result = bar();
  // bar is possibly chugging away doing work, maybe, kinda

  ... lots of other stuff ...

  // NOW we care if bar() has completed, and will do nothing
  // else until it does.
  let actually_the_result = not_the_result.await;
}
```

Ultimately, an `async` function returns a _future_ that will, from your caller's
point-of-view, _block_ when you `.await` until it's satisfied. 

The awesomeness: it's not *really* blocking, in terms of blocking the single MCU
processor from _doing other stuff_. Which is where the real power lies.

# Is it async turtles all the way down?

As noted above, you can only call an async function from within an already async context.
How do you get into async context to start? 

## Executors

An _executor_ is a bit of code that can take an async block as an argument, and _spawn_ it
into an async context where the magic can then happen. The Rust ecosystem has a few executors,
and the embedded Rust ecosystem has a few also. The executor API is pretty much left to the
implementation, so read the docs of whichever you choose.

# Why is this good for embedded?

We generally have a single core, underpowered little processor without a memory-management
unit. We also prefer to statically allocate as much as we can, without over-allocating
memory "just in case" because sometimes we're only rocking 48kb to play with. While
you can certainly implement preemptive threading on an MCU, you would then have to estimate
and reserve stack space per thread, possibly over/under-allocating.

With some strategies, you can precisely allocate memory with async tasks and deterministically
know you won't inadvertantly OOM. If you spawn new tasks willy-nilly, then of course you can
still exhaust your executor's memory pool, but that can be controllable and isolated to
just the executor, not corrupting your entire memory space.

# Let's see an example

I have some proof-of-concept code deep within a secure arctic bunker that I hope to clean up 
and publish shortly, but here's an example of... what else... *blinky*, using `async` and `await`.


```rust
#[entry]
fn main() -> ! {
    rtt_init_print!();
    log::set_logger(&LOGGER).unwrap();
    log::set_max_level(log::LevelFilter::Debug);

    let mut device = Peripherals::take().unwrap();

    log::info!("initializing");
    let mut flash = device.FLASH.constrain();
    let mut rcc = device.RCC.constrain();
    let mut pwr = device.PWR.constrain(&mut rcc.apb1r1);
    let clocks = rcc
        .cfgr
        .sysclk(80.mhz())
        .pclk1(80.mhz())
        .pclk2(80.mhz())
        .freeze(&mut flash.acr, &mut pwr);

    init_executor!( 1024 );

    // NOTE: This is *not* the HAL Timer
    let mut tim15 = crate::timer::Timer::tim15(device.TIM15, clocks, &mut rcc.apb2);

    // NOTE: Since this is *not* the HAL timer, I have to color
    //       outside the lines to enable/reset the apb2
    unsafe {
        (&(*RCC::ptr()).apb2enr).modify(|_,w| w.tim15en().set_bit());
        (&(*RCC::ptr()).apb2rstr).modify(|_,w| w.tim15rst().set_bit());
        (&(*RCC::ptr()).apb2rstr).modify(|_,w| w.tim15rst().clear_bit());
    }

    AsyncTimer::initialize(tim15);

    let mut gpioa = device.GPIOA.split(&mut rcc.ahb2);
    let mut ld1 = gpioa
        .pa5
        .into_push_pull_output(&mut gpioa.moder, &mut gpioa.otyper);

    spawn("ld1", async move {
        loop {
            ld1.set_high().unwrap();
            AsyncTimer::delay(Milliseconds(1000u32)).await;
            ld1.set_low().unwrap();
            AsyncTimer::delay(Milliseconds(1000u32)).await;
        }
    });

    let mut gpiob = device.GPIOB.split(&mut rcc.ahb2);
    let mut ld2 = gpiob
        .pb14
        .into_push_pull_output(&mut gpiob.moder, &mut gpiob.otyper);

    spawn("ld2", async move {
        loop {
            ld2.set_high().unwrap();
            AsyncTimer::delay(Milliseconds(500u32)).await;
            ld2.set_low().unwrap();
            AsyncTimer::delay(Milliseconds(500u32)).await;
        }
    });

    executor::run_forever();
}
```

## What's it do?

It blinks two LEDs. One is on/off every second, the other is on/off every half second.

The two calls to `spawn` are using my _executor_ to start two async contexts. They don't
do a dang thing until `executor::run_forever()` is called, which starts both.

If we view them as two independent tasks, they first turn on their LED. Then they
call an _async function_ named `delay(...)` with the amount of time they want to wait.
That call itself will return a future immediately, which is a pretty poor delay.
But once we `.await` on that future, from each task's point-of-view, it's a blocking
call for 1000 (or 500) milliseconds.

Once the `.await` is satisfied, the task can carry on, toggling it's LED and doing
the `delay(...)` dance again.

Since the `.await` does not actually block the entire processor though, it allows
the other task to keep churning, itself doing real work or possibly `.await`ing.

{{ vimeo(id="489065725") }}

## How's it different from a non-`async` delay?

First, this delay supports many individual delays using a single hardware timer.
Additionally, the normal Embedded HAL `CountDown` timers may use the `nb` non-blocking
crate, but they ultimately block when you wish to delay.

When you have bit of code spinning in a loop checking to see if its delay has expired,
you're preventing other code from doing real work. You're also actively using the
processor, which may prevent some low-power modes. If you have a low-power timer
available to you, there's a high chance that your MCU could go to sleep for 499 milliseconds,
wake up to flip an LED, and then go back to sleep.

# Conclusion

Of course, you *can* write code that blinks two LEDs using interrupts and shared 
resources, but at least to _my_ eye, having self-contained tasks with ostensibly
straight-line logic is easier to think about.

In this implementation, I've glossed over a few facts. First, there *is* an 
interrupt-handler (for `TIM15`) wired up in order for the shared `AsyncTimer`
to know when some deadline has expired. Additionally, the executor I'm using
currently supports exactly 8 tasks, and I've initialized it with 1kb of memory
for storing the async continuation structures that Rust creates behind the
scenes. 

Also, if you want to create something that is asynchronous, you take on the
synchronization burder and end up writing implementations of `Future` which,
while being straight-forward, is also non-trivial.  _Using_ existing async 
functionality is much easier.

Another minor point is that async functions you've called generally won't _actually_
attempt to make progress (in most cases) until you call `.await`. In the
case of our `AsyncDelay` though, that's not completely true. Calling `delay(...)`
registers a deadline, so it is "working" towards it.

But in general, I find `async` embedded code to show much promise, and could
ultimately form the basis for a reactive or actor-like framework for your small
boards.
