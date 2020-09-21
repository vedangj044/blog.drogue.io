+++
title = "WiFi Offloading"
+++

My recent work has been around Cortex-M embedded development using Rust and [RTIC](https://rtic.rs/).
I'm using a handy little development board in the form of the [STM Nucleo-F401RE](https://www.digikey.com/product-detail/en/stmicroelectronics/NUCLEO-F401RE/497-14360-ND/4695525).
Unfortunately, it's handiness stops as soon as you want to communicate with TCP over WiFi, because it lacks WiFi.

<!-- more -->

There also exists another board (using an Xtensa chip) called an [ESP8266](https://www.digikey.com/product-detail/en/sparkfun-electronics/WRL-13678/1568-1235-ND/5725944).

The ESP is nice in that it contains a stock firmware that responds to Hayes AT commands (like a modem) and can do networky types of things.
Then again, the ESP uses Hayes AT commands, which are ASCII-like, across a serial port, which is decidedly less networky feeling from the Rust end of the stick.

# `embedded-nal` (or [Drogue-Network](https://crates.io/crates/drogue-network))

There exists an unpublished Rust crate called `embedded-nal`. 
The "nal" stands for "Network Abstraction Layer". 
This crate acts as an API and contains Rust traits that can be backed by implementations.
Consider it to be akin to the socket-related bits of the POSIX standard.
By itself, it does nothing. 
But with an implementation, higher-level drivers can be written regardless of the underlying networking stack.

Since `embedded-nal` is not-yet-published, I've taken a non-agressive fork and published it as the [`drogue-network`](https://crates.io/crates/drogue-network) crate.

# Let's look at the traits...

I'm initially only concerned wtih TCP, even though the crate also defines a UDP trait.

```rust
/// This trait is implemented by TCP/IP stacks. You could, for example, have an implementation
/// which knows how to send AT commands to an ESP8266 WiFi module. You could have another implemenation
/// which knows how to driver the Rust Standard Library's `std::net` module. Given this trait, you can
/// write a portable HTTP client which can work with either implementation.
pub trait TcpStack {
	/// The type returned when we create a new TCP socket
	type TcpSocket;
	/// The type returned when we have an error
	type Error: core::fmt::Debug;

	/// Open a new TCP socket. The socket starts in the unconnected state.
	fn open(&self, mode: Mode) -> Result<Self::TcpSocket, Self::Error>;

	/// Connect to the given remote host and port.
	fn connect(
		&self,
		socket: Self::TcpSocket,
		remote: SocketAddr,
	) -> Result<Self::TcpSocket, Self::Error>;

	/// Check if this socket is connected
	fn is_connected(&self, socket: &Self::TcpSocket) -> Result<bool, Self::Error>;

	/// Write to the stream. Returns the number of bytes written is returned
	/// (which may be less than `buffer.len()`), or an error.
	fn write(&self, socket: &mut Self::TcpSocket, buffer: &[u8]) -> nb::Result<usize, Self::Error>;

	/// Read from the stream. Returns `Ok(n)`, which means `n` bytes of
	/// data have been received and they have been placed in
	/// `&buffer[0..n]`, or an error.
	fn read(
		&self,
		socket: &mut Self::TcpSocket,
		buffer: &mut [u8],
	) -> nb::Result<usize, Self::Error>;

	/// Close an existing TCP socket.
	fn close(&self, socket: Self::TcpSocket) -> Result<(), Self::Error>;
}
```

Basically it boils down to being able to:

* open
* connect
* write
* read
* close

As with many abstraction crates, this leaves some types relatively undefined, for the implementation to choose.
In this case, the `TcpSocket` type and the `Error` type are both implementation-defined.
From the point-of-view of the `TcpStack` trait, both of those types are opaque.

## Interior mutability

As we know from Rust, methods that take `&self` are immutable, while those that take `&mut self` are mutable.
This trait defines purely non-mutable (in relation to `self`) methods.  
But surely the implementation needs to do some book-keeping when opening/connecting/closing sockets, which
sounds like mutability.

This is a sure sign we probably need [*interior mutability*](https://doc.rust-lang.org/book/ch15-05-interior-mutability.html).

Rust gives us the `RefCell<T>` wrapper that allows just that. 
Calling an immutable method on an immutable object is allowed, and internally the method, _at runtime_ gets a
mutable reference to _something_ that does mutable work.

We'll return to that in a moment.

# Let's talk to our board...

Before we can implement a `TcpStack`, we need to be able to just have a conversation with our ESP8266 as it sits connected to our serial USART pins.

As we discussed in our last post, this involves some board-specific setup, where we:

* get the transmit and receive pins, and convince our F401RE that we want to use them for USART communication.
* get our pins which are connected to the ESP's _enable_ and _reset_ pins, and convince our F401RE that we want to be able to push them high or pull them low.
* use some of those pins to setup a `Serial` port for USART6 running at 115,200bps.
* enable notifications for the RXNE (receive register _not empty_; data is ready for us) interrupt.
* and then split the serial port into 2 halfs: transmit and receive.

```rust
// SERIAL pins for USART6
let tx_pin = pa11.into_alternate_af8();
let rx_pin = pa12.into_alternate_af8();

// enable pin
let mut en = gpioc.pc10.into_push_pull_output();
// reset pin
let mut reset = gpioc.pc12.into_push_pull_output();

let usart6 = device.USART6;

let mut serial = Serial::usart6(
    usart6,
    (tx_pin, rx_pin),
    Config {
        baudrate: 115_200.bps(),
        parity: Parity::ParityNone,
        stopbits: StopBits::STOP1,
        ..Default::default()
    },
    clocks,
).unwrap();

serial.listen(nucleo_f401re::hal::serial::Event::Rxne);
let (tx, rx) = serial.split();
```

But right now all we have is a generic serial port pushing bytes back and forth, without any semantics applied.
Thankfully, we've created an ESP8266 driver, though, which can apply some semantics and gives us an easier-to-use way to interact.
The driver crate gives us an `initialize(...)` free function which consumes both halves of the serial port, along with the _enable_ and _reset_ pins, *plus two queues*.

Why two queues?

The ESP communicates over the serial port in 2 ways:

1. command/response
2. unsolicited messages

These responses and messages will be created from within the interrupt handler from bytes that have arrived and been interpreted, but consumed elsewhere.
Using a [heapless](https://crates.io/crates/heapless) `Queue` allows us to have lock-free `Producer` and `Consumer` to shuffle messages between the contexts.


```rust

static mut RESPONSE_QUEUE: Queue<Response, U2> = Queue(i::Queue::new());
static mut NOTIFICATION_QUEUE: Queue<Response, U16> = Queue(i::Queue::new());

let (adapter, ingress) = initialize(
    tx, rx,
    &mut en, &mut reset,
    unsafe { &mut RESPONSE_QUEUE },
    unsafe { &mut NOTIFICATION_QUEUE },
).unwrap();
```

Now we are holding two objects: an `adapter` which is the user-facing
client for interacting with the esp8266 wifi adapter, an an _ingress_ which can be used from interrupt service routines to process inbound bytes.

# Wiring up the interrupts

As noted above, we're using RTIC. 
RTIC provides a place to do your initialization, and an easy way to wire up interrupt handlers and scheduled tasks, with priorities.
It also provides a way to share resources between these different contexts. 
So at the end of our initializtion process, we stuff the objects into the shared-resources object and return it:

```rust
init::LateResources {
    adapter: Some(adapter),
    ingress,
}
```

## Ingress bytes

When commands are transmitted (via our client `adapter`), the ESP8266 will trigger the `USART6` interrupt for every byte that gets sent back to us.

Thankfully, our `ingress` object is designed to accept those bytes, so it's quick to wire it up to the interrupt:

```rust
#[task(binds = USART6, priority = 10, resources = [ingress])]
fn usart(ctx: usart::Context) {
    if let Err(b) = ctx.resources.ingress.isr() {
        info!("failed to ingress {}", b as char);
    }
}
```

With RTIC, the highest priority task using a resource can use it lock-free, because it can interrupt any other task.
So we just call the `isr()` method on our `ingress` which reads a byte and adds it to an internal buffer.
Interrupt service routines should be _fast_, because they might be called a _lot_. 
In this case, for _every byte that arrives_ at potentially 115,200bps.

## Process bytes

Since the ingressing of bytes needs to be fast, all it does is put it on a buffer and return. 
But at some point, we need to digest those bytes and determine if they are meaningful, or if we're still waiting on more.

For this digesting, we set up a recurring scheduled task, which we schedule the first time from our initialization,
and then it infinitely reschedules itself.

```rust
const DIGEST_DELAY: u32 = 100;

#[task(schedule = [digest], priority = 2, resources = [ingress])]
fn digest(mut ctx: digest::Context) {
    ctx.resources.ingress.lock(|ingress| ingress.digest());
    ctx.schedule.digest(ctx.scheduled + (DIGEST_DELAY * 100_000).cycles())
        .unwrap();
}
```

It's using the same `ingress` resource, but at a lower priority than the USART, so when it fires, it could conceivably
be interrupted by the USART interrupt. By locking the `ingress` object, we can disable that interrupt for a moment and
call our `digest()` method.

The `digest()` method attempts to parse the internal buffer, and figures out if it represents a response to a previously-issued command
or an unsolicited message, and if so, it builds a `Response` object and puts it on the appropriate `Queue` using its `Producer`.

# Where's the WiFi, bucko?

Yeah, we're still not doing WiFi or sockets, are we? 

Let's do that now.

In the idle portion of the app, we can use the `adapter` and magically transform it into a `TcpStack` implementation.

First, since we're going to be transforming our adapter into something else, we'll be mutating it. 
So we have to `take()` it from the `Some(T)` that is holding it on the shared resources, which replaces
it with a `None`.

Next we use it directly to connect to our WiFi. Behind the scenes, calling `'join(...)` for instance
will transmit an AT command, and the response will come back through the USART interrupt and be digested
by the digest task, _seemingly_ in a multi-threaded sort of way. It's not really multi-threaded, the processor
just keeps iterrupting our idle code and itself until a response occurs and our idle code is allowed to proceed.

_Finally_ we can `into_network_stack()` our adapter, which _consumes_ the adapter and gives us back a 
`TcpStack` implementation. Hooray!

```rust
#[idle(resources = [adapter])]
fn idle(ctx: idle::Context) -> ! {

    let mut adapter = ctx.resources.adapter.take().unwrap();

    let result = adapter.get_firmware_info();
    info!("firmware: {:?}", result);

    let result = adapter.join("oddly", "mywifipassword");
    info!("joined wifi {:?}", result);

    let result = adapter.get_ip_address();
    info!("IP {:?}", result);

    let network = adapter.into_network_stack();
    info!("network intialized");

    let socket = network.open(Mode::Blocking).unwrap();
    info!("socket {:?}", socket);

    let socket_addr = SocketAddr::new(
        IpAddr::from_str("192.168.1.245").unwrap(),
        80,
    );

    let mut socket = network.connect(socket, socket_addr).unwrap();

    info!("socket connected {:?}", result);

    let result = network.write(&mut socket, b"GET / HTTP/1.1\r\nhost:192.168.1.245\r\n\r\n").unwrap();

    info!("sent {:?}", result);

    loop {
        let mut buffer = [0; 128];
        let result = network.read(&mut socket, &mut buffer);
        match result {
            Ok(len) => {
                if len > 0 {
                    let s = core::str::from_utf8(&buffer[0..len]);
                    match s {
                        Ok(s) => {
                            info!("recv: {} ", s);
                        }
                        Err(_) => {
                            info!("recv: {} bytes (not utf8)", len);
                        }
                    }
                }
            }
            Err(e) => {
                info!("ERR: {:?}", e);
                break;
            }
        }
    }
}
```

# Dig into the Implementation

We won't walk through all the bits, but to start, our `NetworkStack` is a simple struct, simply
holding a `RefCell` of the previously "consumed" adapter:

```rust
pub struct NetworkStack<'a, Tx>
where
    Tx: Write<u8>,
{
    adapter: RefCell<Adapter<'a, Tx>>,
}
```

Since the `TcpStack` trait requires us to define our own `TcpSocket` type, here's ours:

```rust
/// Handle to a socket.
#[derive(Debug)]
pub struct TcpSocket {
    link_id: usize,
    mode: Mode,
}
```

The ESP8266 supports 5 concurrent connections, identified by a `link_id`, which we use to index into an array.

We've also defined our own `SocketError` error type:

```rust
#[derive(Debug)]
pub enum SocketError {
    NoAvailableSockets,
    SocketNotOpen,
    UnableToOpen,
    WriteError,
    ReadError,
}
```

And here's where we use our `TcpSocket` and `SocketError` and get into the _interior mutability_:

```rust
impl<'a, Tx> TcpStack for NetworkStack<'a, Tx>
where
    Tx: Write<u8>,
{
    type TcpSocket = TcpSocket;
    type Error = SocketError;

    fn open(&self, mode: Mode) -> Result<Self::TcpSocket, Self::Error> {
        let mut adapter = self.adapter.borrow_mut();
        Ok(TcpSocket {
            link_id: adapter.open()?,
            mode,
        })
    }
```

While `open(...)` takes an immutable `self`, we can `borrow_mut()` the adapter we're holding. 
We can then ask the adapter to open a socket for us (or it fails if all 5 are currently in-use)
and we return our `TcpSocket` structure with the recently-opened `link_id`.

# Summary

There's a lot going on to simply open a socket, but when you do embedded, you have to bring a lot
to the table, and like an onion (or a parfait), there's layers upon layers, and thankfully as you
move up the stack, they get simpler and more reusable.

Anyhow, if this seems interesting, here're some links:

* [drogue-network crate](https://crates.io/crates/drogue-network)
* [drogue-esp8266 crate](https://crates.io/crates/drogue-esp8266)
