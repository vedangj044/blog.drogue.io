+++
title = "Down the Yak Hole of TLS"
+++

# Between Rust and TLS, there are a lot of yaks to shave

**Warning: This will be a long and winding blogpost. Grab a cup of coffee.**

We've recently gotten TLS functional for embedded systems in Rust. 
TLS (Transport Layer Security) is one of the backbones to secure communications over TCP/IP, helping protect data in-flight between two parties.
There's a lot of moving parts involved in bringing easy-to-use functional cryptography to small 32-bit ARM Cortex-M devices. 
Let's dive in, shall we?

# Never write a crypto library

One of the primary rules in cryptography is _never write your own cryptography_.
There's a lot of smart people already writing crypto libraries, and also a lot of smart people who are happy to poke holes in your hand-rolled crypto.

Thankfully, ARM has created [mbedTLS](https://tls.mbed.org/) and donated it to [TrustedFirmware.org](https://www.trustedfirmware.org/).
That sounds perfect, yeah?

The downside of *mbedTLS* is that it's written in C, and is able to target not only embedded platforms, but also fully POSIX-compliance large host systems,
which means it is _highly configurable_ and not immediately useful to Rust developers.

# Rust, C, and FFI

Rust *does* provide mechanisms for calling into libraries written in C. 
They are inherently `unsafe` because Rust, rightly, can't trust a library written in C to understand things like _lifetimes_ and Rust's own memory model.

So normally, you find yourself with a `-sys` crate that simply builds the C library, and then wrap that with a Rust crate that provides better safety and semantics.

Then there's issues such as "Rust strings are valid UTF-8 and know their length" and "C strings are a sequence of bytes followed by a null", which complicates matters.

## The `drogue-tls-sys` crate

The first order of business is simply building the mbedTLS library, appropriately configured for an ARM Cortex-M embedded device which lacks things like filesystems, a real-time clock or `printf()`.

Everything configurable with mbedTLS is done through a `config.h` file they ship, defining or undefining a variety of macros which indicate what facilities your platform supports.

By telling mbedTLS that our platform doesn't support traditional things like `calloc(..)`/`free(...)` or `snprintf(...)`,  mbedTLS gives us a way to register function-pointers to those types of things for our platform.  _C function pointers_.  

### Let's look at `calloc(...)`

Once we configure it, mbedTLS gives us this function:

```C
int mbedtls_platform_set_calloc_free( void * (*calloc_func)( size_t, size_t ),
                                      void (*free_func)( void * ) );
```

This allows us to register functions that behave as `calloc(...)` and `free(...)`, allocating and freeing memory on the heap.

By default, embedded Rust doesn't have a heap.

You can install an allocator to give you a heap, but then you also have to install an allocation error handler, which unfortunately is an unstable _nightly-only_ feature of Rust.

How do we solve this?

We fork [alloc-cortex-m](https://crates.io/crates/alloc-cortex-m), and a bit of the Rust alloc crates.

The only reason we have to fork them is because using them directly triggers `rustc` into being convinced we have a global allocator and need to install the allocation error handler, which as noted above, is nightly-only.

#### Allocation in Rust

Rust does allocation using a `Layout` which basically embodies the size of memory you request, along with adjustments for accomodate memory alignment for your platform.
Rust also wants the _exact same layout_ when you deallocate memory, unlike C's `free(...)` which only needs a pointer to the memory.

How do we solve that? The same way C does.

If a request for 16 bytes is made, we add 8 more bytes to that number, and actually ask for 24 bytes of memory. In the first two `usize` slots (4 bytes apiece, times two, for our 8 extra), we scribble in the total size and the alignment so we can reconstitute the `Layout`. We then return a pointer to the 9th byte to C, so it starts using memory *after* our 8-byte header.

```
byte |0   |1   |2   |3   |4   |5   |6   |7   |8                      
     |----|----|----|----|----|----|----|----|-----------------------
 use |alloc_size         |alignment          |handed back to caller  
```

When `free(...)` is called with only a pointer from C code, we back-track 8 bytes, read out the size and alignment values and rebuild our `Layout` to shuffle on into Rust's allocator's `dealloc(...)` method.

This allows us to avoid any external book-keeping, and just taking an extra 8 bytes onto the head of each allocation.

## Bindgen

So far we've glossed over how we _actually_ interface from Rust to C and back.

The answer is [bindgen](https://crates.io/crates/bindgen), which consumes C header files and produces `unsafe` Rust bindings to the API. 

Since Rust has no concept of `null`, but C pointers can certain be null, each pointer tends to get wrapped in a `Option` on the rust side.

We can use the `extern "C"` syntax to write a function in Rust that can be called from C with the appropriate calling conventions. 


```rust
extern "C" fn platform_calloc_f(count: usize, size: usize) -> *mut c_void {
  // do the Layout and allocation dance described above
}
```

Bindgen's processing of mbedTLS also provides us a Rust-callable function `platform_set_calloc_free(...)` exposed by mbedTLS. 
This is where we finally wire stuff up.
But, it's an `unsafe` function that takes function pointers as arguments, so we have to wrap the invocation of it in an `unsafe { ... }` block, and wrap our functions in an `Option::Some(...)`:

```rust
unsafe { platform_set_calloc_free(Some(platform_calloc_f), Some(platform_free_f)) };
```

And now we've _finally_ provided mbedTLS the ability to allocate and deallocate some heap-ish memory.

## Variadics

When working with TLS and doing FFI in general, you need to be able to debug what's actually going on, particular in the two weeks you're banging your head on the table trying to figure out how it all works.
Just like `calloc(...)` above, mbedTLS allows you to pass in a debug logging function. 
The problem is that the things they debug logging function logs tend to be constructed using variants of `sprintf(...)`, which is a _variadic_ function, meaning it can take an unlimited number of arguments to populate the formatting string.

For instance:

```C
printf("%s says %s %d times", bob_str, hi_str, 42);
```

Would print out "Bob says Hi 42 times".

Stable Rust does not support variadics.

In our case, the two important methods are `snprintf(...)` which is a true variadic function, and `vsnprintf(...)` which is slightly less variadic, in that there's an argument that points to the remainder argument list.

It's trivial to write an implementation of `snprintf(...)` in C that delegates to `vsnprintf(...)` which _can_ then be implemented, non-variadically, in Rust.

```C
extern int snprintf(char * restrict str, size_t size, const char * restrict fmt, ...) {
    va_list ap;
    int n;

    va_start(ap,fmt);
    n=vsnprintf(str,size,fmt,ap);
    va_end(ap);

    return n;
}
```

The `va_start(...)` macro ultimately populates the `ap` variable with a pointer to the arguments. 
The arguments are really viewed as an opaque blob of memory, so you must analyze the `printf` formatting string to know how to treat the bytes behind that pointer.

We've create the [drogue-ffi-compat](https://crates.io/crates/drogue-ffi-compat) crate to help deal with that memory interpretation.

```rust
#[no_mangle]
pub extern "C" fn vsnprintf(
    str: *mut u8,
    size: usize,
    format: *const u8,
    ap: va_list,
) -> i32 {
    let mut va_list = VaList::from(ap);
    // use the Rust VaList now
}
```

Now, if you process the `printf` formatting string and see a `%d` you know the next argument is an `i32` in Rust:

```rust
let value: i32 = va_list.va_arg::<i32>();
```

If it's followed by a `%c` you know you can safely interpret the following argument as a character:

```rust
let value: char = va_list.va_arg::<char>();
```

Of course, things will go woefully wrong if you don't have a `printf` formatting string to guide you through walking the `va_list` values.

The `drogue-ffi-compat` crate thankfully includes Just Enough printf formatting string processing to debug mbedTLS.

Just like registering our `calloc()` and `free()` implementation with mbedTLS, we can now register our `snprintf()` and `vsnprintf()` implementations the same way, using similar functions (not pictured, because yeesh, this is getting long).

# The `drogue-tls` crate

The [drogue-tls](https://crates.io/crates/drogue-tls) crate handily wraps up all the machinations above into a _safe_ and more semantic API for dealing with TLS.
It provides an associated function to initialize the system and it sets up the debug logging, etc, and then provides a `TcpStack` for doing network operations.

# That's a lot of yaks. Let's TLS.

Remember, we're doing this so we can put TLS on top of our TCP/IP connections.

If you recall from a previous blogpost, we have created a TCP stack based on using an ESP8266 over our USART. 
We're still doing that. 
But now we'll initialize the TLS platform and wrap it around that network stack to give us a secure network stack.

First, we initialize, providing a 48kb blob of memory for the heap-ish allocation.
We also set up a (terrible) entropy source (this needs to be improved) and see the random-number-generator (RNG):


```rust
let mut ssl_platform = SslPlatform::setup(
    cortex_m_rt::heap_start() as usize,
    1024 * 48).unwrap();

ssl_platform.entropy_context_mut().add_source(StaticEntropySource);

ssl_platform.seed_rng().unwrap();
```

Once our previously-described underlying network stack is fired up and ready to rock, we can borrow it and build ourselves a secure network stack:

```rust
let mut ssl_config = ssl_platform.new_client_config(Transport::Stream, Preset::Default).unwrap();
ssl_config.authmode(Verify::None);

// consume the config, take a non-mutable ref to the network.
let secure_network = SslTcpStack::new(ssl_config, &network);
```

Note, we haven't enabled verification of authentication on the far end. Normally we would have some root Certificate Authority (CA) keys set up and ensure the far end of the connection is who we think it is.
We're skipping that this week.

Our `secure_network` also implements `TcpStack` so we can use it exactly as we used our non-secure stack:

```rust
let socket = secure_network.open(Mode::Blocking).unwrap();

let socket_addr = SocketAddr::new(
    IpAddr::from_str("192.168.1.220").unwrap(),
    8080,
);

let mut socket = secure_network.connect(socket, socket_addr).unwrap();
let result = secure_network.write(&mut socket, b"GET / HTTP/1.1\r\nhost:192.168.1.8\r\n\r\n").unwrap();
```

And we're secure (roughly) in knowledge that our bytes to and from the far end are travelling over an encrypted connection.

That was fun, yeah?
