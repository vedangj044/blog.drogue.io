+++
title = "Nom Parser"
extra.author = "bobmcwhirter"
+++

Routinely we have to deal with recognizing patterns within text or byte streams. 
While LL(k) and LALR are common types of parsers, the [nom crate](https://crates.io/crates/nom) brings [parser combinators](https://en.wikipedia.org/wiki/Parser_combinator) to the embedded Rust world.

<!-- more -->

# Parser Combinators

As their name implies, _parser combinators_ are things that can parse inputs, and can be combined to parser even more complex input.
Similar to LL(k) type of parsing, small atoms are built up into larger, more capable parsing.

# Why we parse

So far we've implemented two drivers for WiFi-offloading boards. 
Both of these boards used some variant of Hayes AT commands in order to communicate with your primary device.

For instance, when joining a WiFi access point, the eS-WiFi board might reply one of two ways:

If successful:

```
[JOIN ] myssid,192.168.2.18,0,0
OK
> 
```

```
[JOIN ] myssid
[JOIN ] Failed
ERROR
> 
```

For the device-driver to be able to turn that into an `Ok` or an `Err`, we have to pluck apart the bits.

## The parser

To start, we notice that every response concludes with a `> ` on a new line.

That parser is pretty easy to write with `nom`:

```rust
named!(
    pub prompt,
    tag!("> ")
);
```

This creates a function named `prompt()` that can take a slice of `[u8]` and attempt to match a `>` followed by a space.

We notice in the successful case, like so many other commands, we might also need to match `OK` on a regular basis.

Let's create a rule for that:

```rust
named!(
    pub ok,
    tag!("OK\r\n")
);
```

Additionally, any error response will include the word `ERROR`, so let's make a rule there.

```rust
named!(
    pub error,
    tag!("ERROR\r\n")
);
```

Also pretty straight-forward.

In the successful case, there's more useful information, such as the assigned IP address that we might want to parse out of the response.
Ignoring the `OK` and the `> ` prompt, we can write a pretty quick parser:

```rust
named!(
    pub(crate) join<JoinResponse>,
    do_parse!(
        tag!("[JOIN   ] ") >>
        ssid: take_until!(",") >>
        char!(',') >>
        ip: take_until!(",") >>
        char!(',') >>
        tag!("0,0") >>
        tag!("\r\n") >>
        ok >>
        (
            JoinResponse::Ok
        )
    )
);
```

Notice we don't have to specifically match many bits. 
We look for the `[JOIN   ] ` blob, and then match everything until the first comma as the SSID. 
We consume that comma, and everything until the next comma is the assigned IP address.
Then you notice, we are using the `ok` parser we already created, to match the `OK\r\n`.
We've chosen to not match the prompt just yet.

The other response, the error case, we can write a very loose parser to match:

```rust
named!(
    pub(crate) join_error<JoinResponse>,
    do_parse!(
        take_until!( "ERROR" ) >>
        error >>
        (
            JoinResponse::JoinError
        )
    )
);
```

Basically, we decide to ignore most everything, and match using our `error` rule above.
Of course, that `join_error` parse rule is pretty ambiguous, but we'll solve that shortly.

## Combining parsers

With `nom` you create your rules, and then you pick one, and attempt to parse a slice of bytes.
It either successfully parses, returning a result along with any remainder slice of unparsed bytes,
or it returns an error, indicating all bytes remain unparsed.

While we're combined the `ok` and `error` parsers into the `join` and `join_error` parsers,
we need some way to glue those two together as another higher-order parser.

Thankfully, `nom` gives us the `alt!(..)` macro to do just that. 
As long as your rules return the same type of result (both are `JoinResponse` in our case),
they can be `alt!`'d together.

A first attempt might look like:

**Warning, will not work as you might hope**

```rust
named!(
    pub(crate) join_response<JoinResponse>,
    do_parse!(
        tag!("\r\n") >>
        response:
        alt!(
              join
            | join_error
        ) >>
        prompt >>
        (
            response
        )

    )
);
```

First, before we address _why_ it doesn't work, let's deconstruct it a bit.

Every response starts with a `\r\n` sequence, which we did not put in either rule, so we match it regardless on our aggregate rule.
Then we pick with `join` or `join_error` and assign it to the `response` variable.
Then we finally match the always trailing `prompt` and return the matches response.

Why doesn't this work?

Because `nom` allows for streaming parsing, knowing that maybe it didn't completely parse something this time, but once you add a few more bytes, maybe it'll match next time.

Given the definition of `join`, we match a given prefix up to a comma.
In the error case, the comma is not present. 
You might think that'd force it to attempt the second option of `join_error` which requires no comma, but nom is an optimist. 
Parsing of `join` did _not fail_, it just hadn't yet succeeded.

Given the way we use the parser, though, we know in our case there are no additional bytes to be expected.
What you've got is all there is, so let's let `nom` know that by wrapping the rules with `complete!(...)`.
This signals that a rule that has not yet succeeded should be considered a failure, and for nom to continue evaluating other alternatives.

```rust
named!(
    pub(crate) join_response<JoinResponse>,
    do_parse!(
        tag!("\r\n") >>
        response:
        alt!(
              complete!(join)
            | complete!(join_error)
        ) >>
        prompt >>
        (
            response
        )

    )
);
```

Now, all we have to do is use the parser, and we'll get back the result we're hoping for:

```rust
let parse_result = parser::join_response(&bytes);

match parse_result {
    Ok((_remainder, response)) => {
        match response {
            JoinResponse::Ok => {
                // yay!
            }
            JoinResponse::JoinError => {
                // bad password or ssid or such
            }
        }
    }
    Err(_) => {
        // something went woefully wrong during parsing
    }
}
```

In this case, we know the slice we parsed was complete, so we can ignore the `_remainder` since it should, in theory, be empty.

# More complex

We've also published an uber-tiny [`drogue-nom-utils` crate](https://crates.io/crates/drogue-nom-utils) to provide helper and utility parsers that we have used more than once.

Some of these adapters will transmit a response like the following to indicate a certain amount of data is available for a certain connection:

```
+IPD,<link_id>,<length>
```

The length portion is simply the characters that make up the length, such as `1024`; a `1` followed by a `0` followed by a `2` and a `4`. 
So we need to parse that as an actual numeric type, not an array of 4 number-looking ASCII characters.
The conversion of ASCII to numbers is usually easy, unless you're `no_std` so we have our own `atoi_usize` to do that for `usize`-sized numbers.
To make a parser combinator that can parse a sequence of ASCII digits and return a single `usize`, we write a function in the style of `nom`:

```rust
pub fn parse_usize(input: &[u8]) -> IResult<&[u8], usize> {
    let (input, digits) = digit1(input)?;
    let num = atoi_usize(digits).unwrap();
    IResult::Ok((input, num))
}
```

Which can then be used like:

```rust
named!(
    pub data_available<Response>,
    do_parse!(
        opt!( crlf ) >>
        tag!( "+IPD,") >>
        link_id: parse_usize >>
        char!(',') >>
        len: parse_usize >>
        crlf >>
        (
            Response::DataAvailable {link_id, len }
        )
    )
);
```

One nice thing about `nom` is that you can feed data forward within a `do_parse!`, using the result of `parse_usize` in another macro such as `take!(len)`.



# Combinators in the tin

While we write our own domain-specific combinators, `nom` ships with a vast array of useful ones beyond the `tag!`, `alt!` and `complete!` that we've seen. 
Each of these macros can also be replaced with function calls if you have some fancy logic you want to involve in your parsing.

A short (and incomplete) list of the combinators we've found useful:

* `alt!`: Try a list of parsers and return the result of the first successful one
* `char!`: matches one character: `char!(char) => &u8 -> IResult<&u8, char>
* `complete!`: replaces a Incomplete returned by the child parser with an Error
* `do_parse!`: 	applies sub parsers in a sequence. it can store intermediary results and make them available for later parsers
* `opt!`: make the underlying parser optional
* `tag!`: declares a byte array as a suite to recognize
* `take!`: generates a parser consuming the specified number of bytes

# Supports `no_std`

Nom works fantastically well, even in a `no_std` environment. 
You can't use the regexp combinators without `std`, but even if you did use regexps, then you'd have two problems.


