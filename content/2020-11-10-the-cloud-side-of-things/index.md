+++
title = "The cloud side of things"
description = "Experimenting with IoT in a serverless world"
extra.author = "ctron"
+++

Up until now, we have focused on "Rust on embedded devices", at least when it comes to writing blog posts. Let's
change that.

<!-- more -->

We already had posts about [WiFi Offloading using the ESP](@/2020-08-24-wifi-offload.md),
[Embedded TLS with Rust](@/2020-09-18-yak-hole-of-tls.md), and [Integrating the es-WiFi over SPI](@/2020-10-12-eswifi.md).
However, what good is an [embedded HTTP client](https://crates.io/crates/drogue-http-client) for, if you have nowhere
to send your data.

## Getting started

Pushing a simple sensor value to a database is simple. Today, everyone can do that. There are so many examples out there,
that show how to use a Raspberry Pi and push some data to a Mosquitto broker. I would argue, that this is nice, and cool,
but no IoT.

Many IoT projects start with a simple PoC. A Raspberry Pi, a bit of script code, some backend process. Off you go!

This is great, because in most cases, people just try to build some kind of application. An application which is built
**on top of** IoT. This may require you to implement some functionality on the device side, and on the backend side.
Without really knowing it, you implemented an HTTP server, simply for serving a static web page.

## Suddenly things get complicated

Then, things tend to get much more complex than anticipated. Adding more devices also increases the number of devices
you need to manage. It also increases the number of messages that hit your backend system. At best, you have a system
that allows you to scale horizontally. That can buffer data, handle peaks gracefully, and helps you manage a huge number
of devices.

Hopefully you won't stop with a single application. The next application however might look slightly different. From
 [XKCD #927](https://xkcd.com/927/) we learned, that there is always a new standard around the corner. *Things*,
especially *industrial things*, tend to have a rather long lifespan. So you need to incorporate new protocols, new
data formats, and new use cases into your system, in order to keep your things running. And, the more devices you
connect, the more sense it makes to interconnect the data.

There a more problems to solve, but I don't want to scare you 😉

### What we need

We need something that allows the developer to focus on the actual use case, and not worry about IoT concerns.

This is important to remember in what comes next. Because our focus is not on the simplicity of solving a single
IoT use case, but to provide a scalable, modular, and interoperable platform that allows you to implement all
different kinds of IoT use cases.

### Knative & Cloud events

[Knative](https://knative.dev/) is a serverless framework for Kubernetes. And please, let's ignore the term
"serverless" for the moment.

Knative helps you build scalable microservices. If you are using Rust to implement them, a microservice starts up
in milliseconds and consumes only a few megabytes of RAM. Knative also offers APIs around the use case of *events*
(aka *messages*). Instead of using a messaging protocol like AMQP or MQTT, Knative builds on top of
[Cloud Events](https://cloudevents.io/).

In a nutshell, Cloud Events describes transport layers and data formats in order to transport events. For example,
for HTTP, that consists of a few HTTP headers, and the HTTP body being the actual payload. But cloud events can also be
represented in different other technologies like HTTP, JSON, Kafka, AMQP, and more. Since there is a common data model,
it is easy to translate between these different technologies.

Knative eventing builds on top of that. Using Kubernetes custom resources, you can deploy event sources, sinks, and
flows, and put translators between the steps. By default, Knative eventing uses the HTTP representation to exchange
events between services, but it is possible to use other representations as well. 

As Knative is "serverless", it can easily scale down to zero, but also scale up as needed.

### Endpoints

In order to support the idea of being protocol agnostic, we provide different protocol endpoints. For a start we have
HTTP (in multiple dialects) and MQTT (v3 and v5). The endpoints are rather small processes, and only translate
between their protocol and the cloud events representation.

The endpoints are payload agnostic and stateless, they only forward what they receive to the next Knative event sink,
and so they are pretty easy to implement.

### Kafka

As there is a Kafka integration with Knative eventing, we are going to use that. The reason for that is simple: First of
all, Kafka is known to scale well, so it fits our use case. Second, we can integrate with Kafka in two ways, using Knative
or directly.

Whenever we can, we try to use the Knative eventing APIs, trying to be interoperable and modular. However, we still
have ability to directly interface with Kafka, and leverage solutions that are more Kafka focused.

## An example

We are in the middle of building this, and you can find an early start at
[drogue-iot/drogue-cloud](https://github.com/drogue-iot/drogue-cloud) on GitHub. There isn't that much code, which is
due to fact that we are still missing some important functionality. But also, because we are leveraging technology
that already exists.

Nevertheless, we are trying to create some end-to-end examples as early as possible. A simple one, publishing a
temperature value, that ends up in a Grafana dashboard. A classic!

![Example](example.svg)

When you take a look at this, please keep in mind what I wrote earlier: we are not trying to make this single,
trivial use case as simple as possible. We try to provide a more versatile solution, that lets you focus on
implementing a solution **on top of** IoT and that still allows you to scale, extend and adapt in the future.

The beauty with the Knative APIs is, that you can easily re-arrange your services. Instead of Kafka as
channel and source, you could to with some other implementation. Or directly connect the HTTP endpoint to the
"Influx DB pusher". Or put some conversion in the middle, …

## What is next?

If you poke around in the repository, you will already find a few other things we are working on. However, I think this
blog post is already long enough, but I also think the topic deserved a bit of introduction, just to explain what our
motivation is, and were we are heading to.

## See also

* [drogue-cloud repository](https://github.com/drogue-iot/drogue-cloud) 
* [Knative](https://knative.dev)
* [Cloud events](https://cloudevents.io)
