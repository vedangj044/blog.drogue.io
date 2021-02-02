+++
title = "Introducing Drogue Device"
description = "Drogue Device is a new async-based actor framework for embedded rust"
extra.author = "bob_and_ulf"
+++

Trying to bring reusable and efficient components to embedded Rust has been a challenge for our team.
We think we've started to make headway, and want to introduce the `Drogue Device` project.

<!-- more -->

# Background

A lot of embedded frameworks and RTOSs rely on procedural coding, "copy these source files into your tree" or a lot of manual connection of APIs to the runtime.
Since _We Are Red Hat_ (or IBM, or more specifically/historically "JBoss"), we like reusable components. And frameworks.
They represent guardrails and provide guidance on how to build larger _systems_, we feel.

## Component Systems

In enterprise software, component systems abound. 
There's Enterprise Java Beans, Actix, CDI, Vert.x, Node.js, Akka framework, Quarkus, Spring, etc.
Many of these component systems tend to rely on multi-threading capability of the underlying system, and bring about concurrency issues, such as shared-state and locking.

## Actor Systems

Of these systems, Akka is an _actor system_, which attempts to draw clear lines about ownership and control of state and data, helping alleviate concurrency concerns.
An actor within an actor system believes that it is single-threaded, serially processing requests that arrive which desire to operate upon the data it controls.
This seemingly single-threaded nature allows an actor to avoid locking of its data. 
All mutations occur from the POV of the actor himself, triggered by _message passing_ from external sources which make requests.

## Messaging

Common messaging patterns include _fire-and-forget_ notifications from one component to another, and _request/response_ between two components.
Sometimes components want to ambiguously broadcast messages to whichever unknown components might be interested. 
This third type is basically an _event bus_.

## Task Scheduling

An actor that thinks it is single-threaded is great, but our MCUs usually also only have one core, and thus one thread.
A slow actor, or one that blocks the thread of execution can bring the entire system to a halt.
Just because one actor hits a wall and can make no further progress, another actor might be able to do some meaningful work, unblocking the first.

### Preemptive Task Scheduling

If you have a preemptive thread or task scheduler, then a kernel is slicing up processor time. 
An task is given a certain number of cycles (or milliseconds, or reductions or whatever unit measurement used to slice the time pie), and when the 
timer expires, the kernel forcibly pause the task and select another one to run for a slice of time.
Naive implementations will allow a blocked task to continue to block until his time-slice expires.
Other implementations allow a task to indicate that it is blocked, and relinquish any remaining time, cooperatively.

### Run-to-Completion Task Scheduling

Some schedulers select a task, and allow it to run to completion, even if it's slow, or blocks briefly. 
The onus is on the developer to ensure his tasks will not completely halt or take too much time. 
Run-to-completion semantics can be great when you have a task you *absolutely* need to have, well, run to completion before being put into the queue to run again later.

### Cooperative Task Scheduling

A cooperative task scheduler allows a task to _run until it can't or doesn't want to run any more_.
In this way, the tasks _must_ cooperate. 
A task may have an infinite loop that never completes, and if he doesn't _pass_ or _yield_ control back, will consume 100% of the processor, 100% of the time.
This is a sub-optimal situation.
Cooperative task scheduling can be improved by language support for _asynchronous_ architectures, where the language can implicitly be aware when a task can no longer make progress.
This results in the task being immediately pulled off the active queue, and another _ready and waiting_ task to be selected to do some work.
This doesn't solve the tight-loop problem, where a task must still cooperatively _pass_ control back to the kernel.

# `Drogue Device` Architecture

Given the above background, along with implementing an untold number of proofs-of-concept, we've selected the following key points for our system:

* Actor-based: State is held by an actor, accessed/mutated only by that actor, in response to messages.
* Cooperative Scheduling: Using Rust's `async/await` support, actors attempt to be non-blocking and share the processor.
* Message-Passing: Support _notifications_, _requests/responses_, and an _event-bus_.

## The Actors

First, being an actor system, the primary point-of-interest is the _actor_. 
Drogue Device supports _two_ flavors of actor: Plain Ol' Actors and Interrupt Actors.

### Plain Ol' Actors

The general case of an actor is a component that contains state, and can manipulate it in response to messages.
Their *only* interface with the outside world is messages. 
To ensure that no other code can directly twiddle an actor, the primary handle on an actor is an `Address<A>` instance.
It is through the `Address<A>` of an actor `A` that any part of the system can communicate with the actor.
All methods upon `Address<A>` are immutable, and the addresses can be freely `clone()`'d and shared around.

As noted above, there are two types of message interactions possible with an actor through it's `Address<A>`:

#### Notify

```rust
pub fn notify<M>(&self, message: M)
where
    A: NotifyHandler<M> + 'static,
    M: 'static,
{
    ... elided ...
}
```

This signature demonstrates a few points:

* The system is ultimately `'static`-centric.
* You can send a message `M` if the underlying `Actor` implements the `NotifyHandler<M>` trait.

A `notify(...)` is a non-blocking synchronous call, meaning that it won't stop the processing and it can be called from any context, sync or async.
It ultimately enqueues the message into a FIFO for the actor. 
Some systems refer to this FIFO as the actor's "inbox".
Messages in the FIFO are indeed processed in a first-in-first-out order.
This also means that the message is _not_ processed immediately upon the call of `notify(...)`.
This gives this method _fire and forget_ semantics.
The actor will be mostly (see **NB** below)  guaranteed to eventually process the notification, at some point in the future.

_**NB:** Currently the FIFO is set to a depth of 16, and if it overflows messages will be silently discarded.
We understand this is sub-optimal. 
The intention is that once _const generics_ are available in stable Rust we will allow per-actor queue depth configuration.
Additionally, we are considering how different overflow strategies may be applied per-actor._

On the `Actor` side, processing is handled through an implementation of the `NotifyHandler<M>` trait, for each type of message that is considered acceptable:

```rust
pub struct On;
pub struct Off;

impl<P,A> NotifyHandler<On> for SimpleLED<P,A>
where
    P: OutputPin,
    A: ActiveOutput,
{
    fn on_notify(&'static mut self, message: On) -> Completion {
        ... elided ...
    }
}

impl<P,A> NotifyHandler<Off> for SimpleLED<P,A>
where
    P: OutputPin,
    A: ActiveOutput,
{
    fn on_notify(&'static mut self, message: Off) -> Completion {
        ... elided ...
    }
}
```

#### Request

Sometimes it's useful to have a somewhat synchronous interactino with an actor in an _request/response_ type of cycle.
The `Address<A>` type also provides that capability:

```rust
pub async fn request<M>(&self, message: M) -> <A as RequestHandler<M>>::Response
where
    A: RequestHandler<M> + 'static,
    M: 'static,
{
    ... elided ...
}
```

The first thing to note is that because `Address<A>` is a _type_ and not a _trait_, it can indeed support `async` methods.
The second thing to note is that `request(...)` **is** an `async` method.
Upon calling this method, a `Future` is ultimately returned, and the called _must_ `.await` the response, per usual Rust async semantics.

It is the async nature of this method that allows actors to talk to other actors and remain non-blocking and cooperatively schedulable.

As with the `notify(...)` method, this method is also considered immutable, and uses the underlying actor's FIFO.
The same FIFO is shared between all types of messages that an actor can be notified or requested.

On the `Actor` side, as with the `NotifyHandler<M>`, there is a `RequestHandler<M>` trait to be implemented for each type of request an actor needs to be able to handle.

```rust
pub struct Lock;

impl<T> RequestHandler<Lock> for Mutex<T>
where
    T: 'static,
{
    type Response = Exclusive<T>;

    fn on_request(&'static mut self, message: Lock) -> Response<Self::Response> {
        ... elided ...
    }
}
```

### Interrupt Actors

Extending on the Plain Ol' Actors are Interrupt actors, which in addition to doing all the things an actor can do, *also* is cognizant and connected to hardware interrupts.
Interrupts are special, because they can arrive at any time, and they are not initiated as a message from another actor.
So interrupts are treated somewhat specially.

An interrupt firing can be considered a special type of message, without content. 
To that end, the `Interrupt` trait brings one more method to implement: `on_interrupt(...)`:

```rust
impl<D, PIN> Interrupt for Button<D, PIN>
where
    D: Device + EventHandler<ButtonEvent> + 'static,
    PIN: InputPin + ExtiPin,
{
    fn on_interrupt(&mut self) {
        ... elided ...
    }
}
```

## Message-handling and `async`

Since Drogue Device attempts to provide guardrails for performing asynchronous operations where possible, but Rust doesn't currently support `async` in traits,
you may have noticed that all of the aforementioned `NotifyHandler<M>` and `RequestHandler<M>` methods were not, at all, `async`.
Additionally, their return value in the signatures may have appeared slightly odd.
Also, each method takes a `&'static mut self` reference. 
It's `` `static `` because the system is static, and Futures work best with `` `static` ``. 
It's `&mut` because the scheduler guarantees that the actor's methods are serialized and ensures that a given handler is the only reference (mutable or not) 
for the actor at any given point in time.
This allows the actor to free, without locks, mutate his own state.

### `on_notify`

Let's look at the _fire-and-forget_ `NotifyHandler<M>` on an actor.

```rust
fn on_notify(&'static mut self, message: M) -> Completion;
```

Even though `Address<A>::notify(...)` returns nothing, the handler implemented on the actor must return a `Completion`, which is where the opportunity to perform asynchronous
processing arrives.

If the processing is quick and non-blocking, a simple implementation can do whatever work it needs to do and return `Completion::Immediate` to signal 
that the message was immediately processed to completion. 

An `::immediate()` function is provided to create a `Completion::Immediate` for the return value.

```rust
fn on_notify(&'static mut self, message: M) -> Completion {
    self.counter += 1;
    Completion::immediate()
}
```

If in response to a message an actor needs to perform some other action, such as making an `async` request to _another_ actor, a `Completion::Defer(...)` is available,
which ultimately wraps an `async` block.  
The executor will attempt to avoid a context-switch and begin executing the returned async block as far as possible before swapping to another task.

A `::defer(...)` function is provided to create a `Completion::Defer(...)` for the return value.


```rust
fn on_notify(&'static mut self, message: M) -> Completion {
    Completion::defer( async move {
        self.counter += self.other_actor.request( SomeMessage ).await;
    })
}
```

### `on_request`

As with `on_notify`, the `on_request(...)` method _also_ takes the same flavor of `&'static mut self` and provides both an immediate and defer variant of `Response<T>`, but allow for the
return-value as specified in the associated type of `RequestHandler`.

An immediate response is allowed if `async` is not required:

```rust
fn on_request(&'static mut self, message: M) -> Response<Self::Response> {
    Response::immediate(42)
}
```

If an async block is needed:

```rust
fn on_request(&'static mut self, message: M) -> Response<Self::Response> {
    Response::defer( async move {
        let response = self.some_other_actor.rqeuest( AnotherMessage ).await;
        response.favorite_cheese
    } )
}
```

### `on_interrupt`

For actors that also implement `Interrupt`, their `on_interrupt(...)` method may be called when the associated interrupt fires.
Since interrupts must return quickly, this is a simple, normal, non-async method without opportunity of deferring to an `async` block:

```rust
fn on_interrupt(&mut self) {
    self.some_other_actor.notify( SomethingHappened );
}
```

This also implies that `Interrupt` implementations can only use `notify(...)` on other actors, and not make asynchronous `request(...)`
calls.

### General `async` Executor

**There isn't one.**

Drogue Device explicitly does not support arbitrary `spawn(...)`ing of `async` blocks.
All asynchronous activity takes place through coordination of actors and their FIFO queues.

_There is an async executor, you're just not allowed to touch it directly._

# Wiring it all together

So far we've explored the various actor, address, message-handlers and async aspects, so let's now examine how we connect it all together.

## The `Device`

At the root of an actor system is a `Device`. 
This is a user-constructed type that ultimately ends up holding all of the other `Actor` and `Interrupt`s, but indirectly.
When the system is started, the entire tree, from the `Device` on down is moved into a `'static` context, which is how
all of the message-handlers end up taking a `&'static mut self`. 

This example will use an STM32 B-L4S5I-IOT01A board, but the same principals apply to others, even if the pinout is different.

### The Type

For ease, a simple type with public members can be defines. 
Since nothing should actually hold an `Actor` directly, each Actor or Interrupt is ultimately held in a matching _context_.
Type aliases have been used to simplify the signatures since generics are quite prevalent.

An actor has been specified for each of the two LEDs on this board, along with an interrupt actor for the button.
Additionally, two `Blinker` actors and a timer actor are also specified.
Since hardware timers are interrupt-driven, it is an interrupt actor.

```rust
pub struct MyDevice {
    pub ld1: ActorContext<Ld1Actor>,
    pub ld2: ActorContext<Ld2Actor>,
    pub blinker1: ActorContext<Blinker1Actor>,
    pub blinker2: ActorContext<Blinker2Actor>,
    pub button: InterruptContext<ButtonInterrupt>,
    pub timer: InterruptContext<TimerActor>,
}
```

### The `Device` Implementation

A single method is required when implementing `Device`: `mount(...)`.

When the system is started, the device will be automatically mounted into it. 
Since the device holds the other actors and interrupts, it _must_ propagate the mount down to the children in order to activate them within the system also.
Upon mounting each child, its `Address<A>` will be returned.

Each Actor can optionally implement a `Bind<OTHER_ACTOR:Actor>` method to have a way to inject another actor's `Address<A>` into it.
This is one way inform an actor of another actor during the `mount(...)` cycle.


```rust
impl Device for MyDevice {
    fn mount(
        &'static mut self,
        bus_address: &Address<EventBus<Self>>,
        supervisor: &mut Supervisor,
    ) {
        let ld1_addr = self.ld1.mount(supervisor);
        let ld2_addr = self.ld2.mount(supervisor);

        let blinker1_addr = self.blinker1.mount(supervisor);
        let blinker2_addr = self.blinker2.mount(supervisor);

        let timer_addr = self.timer.mount(supervisor);

        blinker1_addr.bind(&timer_addr);
        blinker1_addr.bind(&ld1_addr);

        blinker2_addr.bind(&timer_addr);
        blinker2_addr.bind(&ld2_addr);

        let button_addr = self.button.mount(supervisor);
        button_addr.bind(bus_address);
    }
}
```

In the code above, each `Blinker` actor gets `bind(...)` called twice: once for the LED it needs to blink, and once for the shared `Timer`.

The `Button` actor gets bound to the address of the `EventBus` which we will touch on later.

### The Setup

Using bare-metal Rust, we set up the actors and the device in a normal `#[entry]`:

```rust
#[entry]
fn main() -> ! {
    rtt_init_print!();
    log::set_logger(&LOGGER).unwrap();
    log::set_max_level(log::LevelFilter::Debug);

    let mut device = Peripherals::take().unwrap();

    log::info!("[main] Initializing");
    let mut flash = device.FLASH.constrain();
    let mut rcc = device.RCC.constrain();
    let mut pwr = device.PWR.constrain(&mut rcc.apb1r1);
    let clocks = rcc
        .cfgr
        .sysclk(80.mhz())
        .pclk1(80.mhz())
        .pclk2(80.mhz())
        .freeze(&mut flash.acr, &mut pwr);

    let mut gpioa = device.GPIOA.split(&mut rcc.ahb2);
    let mut gpiob = device.GPIOB.split(&mut rcc.ahb2);
    let mut gpioc = device.GPIOC.split(&mut rcc.ahb2);
    let mut gpiod = device.GPIOD.split(&mut rcc.ahb2);

    // == LEDs ==

    let ld1 = gpioa
        .pa5
        .into_push_pull_output(&mut gpioa.moder, &mut gpioa.otyper);

    let ld1 = SimpleLED::new(ld1, Active::High);

    let ld2 = gpiob
        .pb14
        .into_push_pull_output(&mut gpiob.moder, &mut gpiob.otyper);

    let ld2 = SimpleLED::new(ld2, Active::High);

    // == Blinker ==

    let blinker1 = Blinker::new(Milliseconds(500u32));
    let blinker2 = Blinker::new(Milliseconds(1000u32));

    // == Button ==

    let mut button = gpioc
        .pc13
        .into_pull_up_input(&mut gpioc.moder, &mut gpioc.pupdr);

    button.make_interrupt_source(&mut device.SYSCFG, &mut rcc.apb2);
    button.enable_interrupt(&mut device.EXTI);
    button.trigger_on_edge(&mut device.EXTI, Edge::RISING_FALLING);

    let button = Button::new(button, Active::Low);

    // == Timer ==

    let mcu_timer = McuTimer::tim15(device.TIM15, clocks, &mut rcc.apb2);
    let timer = Timer::new(mcu_timer);

    // == Device ==

    let device = MyDevice {
        ld1: ActorContext::new(ld1).with_name("ld1"),
        ld2: ActorContext::new(ld2).with_name("ld2"),
        blinker1: ActorContext::new(blinker1).with_name("blinker1"),
        blinker2: ActorContext::new(blinker2).with_name("blinker2"),
        button: InterruptContext::new(button, EXTI15_10).with_name("button"),
        timer: InterruptContext::new(timer, TIM15).with_name("timer"),
    };

    device!( MyDevice = device; 1024 );
}
```

Each actor is directly constructed and configured within the `#[entry]`, wrapped in the appropriate context and attached to the `device`.
You will notice that `InterruptContext::new(...)` also takes an IRQ to be connected to the underlying actor.
When the associate interrupt fires, the actor's `on_interrupt(...)` will be triggered.

Optionally, each context can be associated with a name, which can make debugging or logging easier in a multi-actor system, particular
when working with several actors of the same type.

## The `device!(...)` magic

The last line of the `#[entry]` specifies the type implementing `Device`, the device itself, plus the size of memory to reserve for
asynchronous book-keeping. In this case, 1024 bytes is allotted.

The `device!(...)` macro never returns and is a suitable last line for `#[entry]`.

At this point, the system is running.

# Explore the Example

All of the example actors in our system are part of the `drogue-device` crate.

## LEDs

Each LED is a `SimpleLED` actor, which is parameterized by the appropriate digital `OutputPin` and an `Active` state which describes if it's active-high or active-low.
Each LED can handle a notification of simple `On` or `Off` messages:

```rust
impl<P,A> NotifyHandler<On> for SimpleLED<P,A>
where
    P: OutputPin,
    A: ActiveOutput,
{
    fn on_notify(&'static mut self, message: On) -> Completion {
        self.turn_on();
        Completion::immediate()
    }
}

impl<P,A> NotifyHandler<Off> for SimpleLED<P,A>
where
    P: OutputPin,
    A: ActiveOutput,
{
    fn on_notify(&'static mut self, message: Off) -> Completion {
        Completion::defer(async move {
            self.turn_off();
        })
    }
}
```

### Magic with `Address<SimpleLED<...>>`

Since the `SimpleLED` is implemented within the `drogue-device` crate, along with `Address`, we can actually extend `Address<SimpleLED<...>>` to provide handy API methods.

```rust
impl<S> Address<S>
where
    S: NotifyHandler<Off> + NotifyHandler<On>,
    S: Actor + 'static,
{
    pub fn turn_on(&self) {
        self.notify(On);
    }

    pub fn turn_off(&self) {
        self.notify(Off);
    }
}
```

Now, anyone holding an `Address<SimpleLED<...>>` does not even have to think in terms of `notify(On)` or `notify(Off)`, but can directly call `turn_on()` and `turn_off()`.

## Timer

The `Timer` actor was constructed using a hardware timer of our platform, and wired to the appropriate interrupt.
The timer is a shared resource, capable of providing asynchronous delays or scheduling future delivery of messages.

Since an asychronous delay is asynchronous and must be awaited, it is implemented as a `RequestHandler<Delay<...>>`.

```rust
impl<T: HalTimer, DUR: Duration + Into<Milliseconds>> RequestHandler<Delay<DUR>> for Timer<T> {
    type Response = ();

    fn on_request(&'static mut self, message: Delay<DUR>) -> Response<Self::Response> {
        ... elided ...
    }
}
```

The request has no meaningful response type, but the `.await` from the caller will only return once the delay has expired.

We'll be using the `Schedule` message type, which simply asks the timer to deliver, via `notify(...)` some message to some address at some point in the future.

```rust
impl<T, E, A, DUR> NotifyHandler<Schedule<A, DUR, E>> for Timer<T>
where
    T: HalTimer,
    E: Clone + 'static,
    A: Actor + NotifyHandler<E> + 'static,
    DUR: Duration + Into<Milliseconds> + 'static,
{
    fn on_notify(&'static mut self, message: Schedule<A, DUR, E>) -> Completion {
        ... elided ...
    }
} 
```

## Blinker

If you recall, our `Blinker` was bound to both the LED and the timer.
Since its own address, along with that of the LED and Timer are not known at construction time, it has `Option<Address<...>>` fields for populating later, during start-up or via `bind(...)` calls.

```rust
pub struct Blinker<S, T>
where
    S: Switchable,
    T: HalTimer,
{
    led: Option<Address<S>>,
    timer: Option<Address<Timer<T>>>,
    address: Option<Address<Self>>,
    delay: Milliseconds,
}
```

The `Blinker` implements some methods on the `Actor` trait which allow it to learn of its own `Address` and to perform some action at start-up.
In this case, it schedules a message of `State::On` back to itself after `delay` milliseconds when it starts.

```rust
impl<S, T> Actor for Blinker<S, T>
where
    S: Switchable,
    T: HalTimer,
{
    fn mount(&mut self, address: Address<Self>)
    where
        Self: Sized,
    {
        self.address.replace(address);
    }

    fn start(&'static mut self) -> Completion {
        self.timer.as_ref().unwrap().schedule(
            self.delay,
            State::On,
            self.address.as_ref().unwrap().clone(),
        );
        Completion::immediate()
    }
}
```

When the timer delivers that future-scheduled message, it will take action on it, and scheduler another message to itself to get a blinking LED, toggling forever.

```rust
impl<S, T> NotifyHandler<State> for Blinker<S, T>
where
    S: Switchable,
    T: HalTimer,
{
    fn on_notify(&'static mut self, message: State) -> Completion {
        match message {
            State::On => {
                self.led.as_ref().unwrap().turn_on();
                self.timer.as_ref().unwrap().schedule(
                    self.delay,
                    State::Off,
                    self.address.as_ref().unwrap().clone(),
                );
            }
            State::Off => {
                self.led.as_ref().unwrap().turn_off();
                self.timer.as_ref().unwrap().schedule(
                    self.delay,
                    State::On,
                    self.address.as_ref().unwrap().clone(),
                );
            }
        }
        Completion::immediate()
    }
}
```

We also can envision wanting to change the speed of the blinking during the course of the system running, so we provide a `NotifyHandler<AdjustDelay>` to the `Blinker`:

```rust
pub struct AdjustDelay(Milliseconds);

impl<S, T> NotifyHandler<AdjustDelay> for Blinker<S, T>
where
    S: Switchable,
    T: HalTimer,
{
    fn on_notify(&'static mut self, message: AdjustDelay) -> Completion {
        self.delay = message.0;
        Completion::immediate()
    }
}
```

Once again, also, we add some fluent API to instances of `Address<Blinker<...>`:

```rust
impl<S, T> Address<Blinker<S, T>>
where
    Self: 'static,
    S: Switchable,
    T: HalTimer,
{
    pub fn adjust_delay(&self, delay: Milliseconds) {
        self.notify(AdjustDelay(delay))
    }
}
```


## Button (and the EventBus)

The `Button` is an interrupt-based actor. While we could have used `bind(...)` to target a specific recipient of its `ButtonEvent::Pressed` or `ButtonEvent::Released` messages, 
that would have tightly-bound the target to the semantics of the button.

Instead, the `Button` is bound to the `Address<EventBus<...>>` during the `Device` mount, in order to delegate what action to take to a loosely-coupled actor.

```rust
pub struct Button<D: Device, PIN> {
    pin: PIN,
    active: Active,
    bus: Option<Address<EventBus<D>>>,
}

impl<D, PIN> Bind<EventBus<D>> for Button<D, PIN>
where
    D: Device,
{
    fn on_bind(&'static mut self, address: Address<EventBus<D>>) {
        self.bus.replace(address);
    }
}

```

When the interrupt fires, its `on_interrupt(...)` method is invoked, where it calls `notify(...)` on the `EventBus<...>` address.

```rust
impl<D, PIN> Interrupt for Button<D, PIN>
where
    D: Device + EventHandler<ButtonEvent> + 'static,
    PIN: InputPin + ExtiPin,
{
    fn on_interrupt(&mut self) {
        if self.pin.check_interrupt() {
            match self.active {
                Active::High => {
                    if self.pin.is_high().ok().unwrap() {
                        self.bus
                            .as_ref()
                            .unwrap()
                            .publish(ButtonEvent::Pressed);
                    } else {
                        self.bus
                            .as_ref()
                            .unwrap()
                            .publish(ButtonEvent::Released);
                    }
                }
                Active::Low => {
                    if self.pin.is_low().ok().unwrap() {
                        self.bus
                            .as_ref()
                            .unwrap()
                            .publish(ButtonEvent::Pressed);
                    } else {
                        self.bus
                            .as_ref()
                            .unwrap()
                            .publish(ButtonEvent::Released);
                    }
                }
            }
            self.pin.clear_interrupt_pending_bit();
        }
    }
}
```

### What is the `EventBus`?

So far we've glossed over the `EventBus`. 
The `EventBus` is _your device_. 
Your device provides all logic for what happens to messages sent to the `EventBus` address, in order to apply application semantics.

Just as actors and interrupts can implement `NotifyHandler<M>` and `RequestHandler<M>`, your `Device` can (and _must_) implement `EventHandler<M>` for all events destined to the `EventBus`.

```rust
impl EventHandler<ButtonEvent> for MyDevice {
    fn on_event(&'static mut self, message: ButtonEvent)
    where
        Self: Sized,
    {
        match message {
            ButtonEvent::Pressed => {
                log::info!("[{}] button pressed", ActorInfo::name());
                self.blinker1.address().adjust_delay(Milliseconds(100u32));
            }
            ButtonEvent::Released => {
                log::info!("[{}] button released", ActorInfo::name());
                self.blinker1.address().adjust_delay(Milliseconds(500u32));
            }
        }
    }
}
```

Since your `Device` maintains the contexts for each component, it can obtain the address for each, and send notifications down the line.
In this case, when the button is pressed, our `Device` translates that into adjusting the delay for the `Blinker` that controls LED 1.
Upon releasing the button, it re-adjusts the delay.

The end result is pressing the button speeds up the blinking until the button is released.

And the button is ignorant of the LED, and the LED is ignorant of the button. 
You device provides the glue between two disparate component message semantics.

# Other Bits in the Tin

While LEDs and Buttons are nice, `drogue-device` also provides within the crate concurrency actors, such as `Mutext<T>` and `Semaphore`.
Additionally, Ulf has recently worked on UART support that does not require `'static` messages.

We also aim to include device drivers directly in-tree.

# Future directions

There's a _lot_ of work left to do, much of which will be bringing significantly more async support to various MCUs and HALs.
There is probably a lot of API clean-up that can be done, in order to make implementing actors easier.
We mentioned way way earlier, we intend to make each actor's FIFO more configurable to allow for more tailored overflow behaviour.
Being able to dynamically adjust the priority of the async tasks is also a goal.

We welcome any and all contributions to the project. Feel free to drop by our Matrix chat (see sidebar) or use our Discourse server.

