+++
title = "Minikube Roundtrip"
description = "Posting data from an IoT device to a Knative service deployed on Minikube"
extra.author = "jcrossley"
+++

[Minikube](https://minikube.sigs.k8s.io/docs/) is a convenient tool
for developing Kubernetes services on your laptop, but how can you
access them from your IoT device? In this article, we'll walk through
deploying the
[drogue-cloud](https://github.com/drogue-iot/drogue-cloud) project on
minikube and then post data to its knative endpoint via an ESP8266
WiFi module.

<!-- more -->

# tl;dr

We'll cover the gory details below, but the crux of the biscuit for
accessing _any_ knative service on minikube from a remote device is to
first set up a port-forward on your laptop, and then override the
`Host` header when connecting to that port from your device.

On your laptop, forward HTTP requests on port 8080 to knative's
ingress running on minikube...

```shell
kubectl port-forward --address 0.0.0.0 svc/kourier -n kourier-system 8080:80
```

On your device, connect to your laptop's IP address on port 8080, but
set the HTTP `Host` header to match the URL of the knative endpoint...

```shell
kubectl get ksvc -n drogue-iot http-endpoint -o jsonpath='{.status.url}'
```

It's this `Host` header that ensures your request is routed to the
proper service. And now, as promised, the details...

# Configure Minikube

You're gonna need a lot of RAM! Like, at least 10 GB. And let's say
double that amount of disk...

Still reading? Great! 

The drogue-cloud repo is a bit of a playground. We include a lot of
resource-hungry services such as [knative](https://knative.dev/) --
both [serving](https://github.com/knative/serving) and
[eventing](https://github.com/knative/eventing) -- and
[strimzi](https://strimzi.io/). 

Instructions for starting minikube with the required resources,
versions, and addons are
[here](https://github.com/drogue-iot/drogue-cloud/blob/main/deploy/minikube.adoc). Essentially,
you'll run this:

```shell
minikube start --cpus 4 --memory 10240 --disk-size 20gb --addons ingress
```

In addition, you'll need to fire up [minikube
tunnel](https://minikube.sigs.k8s.io/docs/commands/tunnel/) in a
separate shell to enable LoadBalancer type services.

```shell
minikube tunnel
```

# Deploy drogue-cloud

With minikube up and running, installing drogue-cloud should be as simple as this: 

```shell
git clone https://github.com/drogue-iot/drogue-cloud
cd drogue-cloud
./hack/drogue.sh
```

If it fails, it's likely because it can't find [one of
these](https://github.com/drogue-iot/drogue-cloud/blob/main/deploy/README.adoc#pre-requisites). You
can safely restart it after installing the one it's complaining about
as the `drogue.sh` script is idempotent.

It will take a few minutes to finish. When it finally does, you should
see output similar to this:

```shell
==========================================================================================
 Base:
==========================================================================================

SSO:
  url:      http://172.17.0.3
  user:     admin
  password: admin123456

Console:
  url:      http://172.17.0.3:30046
  user:     admin
  password: admin123456

------------------------------------------------------------------------------------------
Examples
------------------------------------------------------------------------------------------

View the dashboard:
---------------------

* Login to Grafana:
    url:      http://172.17.0.3:32656
    username: admin
    password: admin123456
* Try this link: http://172.17.0.3:32656/d/YYGTNzdMk/
* Or search for the 'Knative test' dashboard

Publish data:
----------------

At a shell prompt, try these commands:

  http POST http://http-endpoint.drogue-iot.10.96.168.111.nip.io/publish/device_id/foo temp:=44
  mqtt pub -v -h 172.17.0.3.nip.io -p 31677 -s --cafile tls.crt -t temp -m '{"temp":42}' -V 3
```

This shows the URL's for the drogue-cloud services specific to your
minikube. You can generate this output at any time with this script:

```shell
./hack/status.sh
```

# Configure your device

That `http POST ...` example command near the end of the above output
is what you'll use in your device code to set the `Host` header.

An [extremely rudimentary
application](https://github.com/jcrossley3/stm32f401-blinky/blob/0e97ed4c2d256376ea61c30701288642f34c0209/src/main.rs)
based on the [RTIC framework](http://rtic.rs) demonstrates the posting
of a single piece of data to the `http-endpoint` using the
[drogue_esp8266](https://github.com/drogue-iot/drogue-esp8266),
[drogue_network](https://github.com/drogue-iot/drogue-network), and
[drogue_http_client](https://github.com/drogue-iot/drogue-http-client)
crates.

Relevant sections of the code -- replicated below -- include
[configuring the
app](https://github.com/jcrossley3/stm32f401-blinky/blob/0e97ed4c2d256376ea61c30701288642f34c0209/src/main.rs#L4-L8)
for your local network and minikube, [creating the correct IP
address](https://github.com/jcrossley3/stm32f401-blinky/blob/0e97ed4c2d256376ea61c30701288642f34c0209/src/main.rs#L101-L104),
and finally the [HTTP POST
request](https://github.com/jcrossley3/stm32f401-blinky/blob/0e97ed4c2d256376ea61c30701288642f34c0209/src/main.rs#L121-L126).

```rust
const HOST: &str = "192.168.0.110";    // laptop IP
const HOST_HEADER: &str = "http-endpoint.drogue-iot.10.96.168.111.nip.io";
  ...
let socket_addr = HostSocketAddr::new(
    HostAddr::from_str(HOST).unwrap(),
    8080,
);
  ...
let mut req = con
    .post("/publish/esp8266/dummy")
    .headers(&[("Host", HOST_HEADER),
               ("Content-Type", "text/json")])
    .handler(handler)
    .execute_with::<_, U512>(&mut tcp, Some(data.as_bytes()));
```

Obviously, unless you happen to have an STM32F401 board connected to
an ESP8266 module via USART6, [this
code](https://github.com/jcrossley3/stm32f401-blinky/tree/esp8266) is
not going to work for your device, but hopefully there's at least
enough here you can use if you're looking to get a little Rust-y IoT
in your mini-kubernetes!
