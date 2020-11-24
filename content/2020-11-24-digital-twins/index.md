+++
title = "Digital Twins, and how they can help"
description = "A quick introduction in digital twins, what they offer and how they can be used in the context of Drogue IoT"
extra.author = "ctron"
+++

Exchanging messages with devices is great. As I tried to explain in the last blog post about
[the cloud side of things](@/2020-11-10-the-cloud-side-of-things/index.md), having a modular system, and
normalizing the transport protocol can make things a lot easier. However, exchanging messages is only the first
step towards an IoT application.

<!-- more -->

## Blinkedy blink

Maybe you noticed, maybe not … but Rodney blinks, every now and then. Just like devices send data, every now and then.
And it is easy for devices to implement that. A change happens, message sent. That's it.

However, on the consuming side of those changes, receiving the information of a change is equally important as the
current state of the device. Or maybe event group of devices.

Just to visualize what I mean. I bet you did take a look Rodney a few seconds back. What you saw, was:

![Blinking](rodney.png)

Now you are the process, consuming on the cloud side, and the image is the overall state of your device. You expect
the see the full picture, literally. Just assume what it would look like, not having the previous state, only the
changes:

![Blinking](rodney_diff.png)

It would start out blank, because you never had the initial state. Then, it would change, but the change itself doesn't
make any sense. Neither would the change back.

For the device, it would be convenient tough, to only the most recent change. For the network that would be easier to
handle as well, as it means less data.

However, for the consuming side, it would be harder to process. Because the information about the *current state* is
not easily available.

## Current state

Let's take a simple dashboard as an example, showing the most recent temperate value. That is easy to implement with
our current example application. The *most recent* state of that sensor is always available in our time series database.

Assuming a more complex example, of a more complex device, with much more data. We cannot push everything into a
time series database. That would take up too much space and would also be not feasible for some of the data formats.

So we do need some kind of storage, which persists the *last known* state of a device. And you need a way to keep
the data fresh.

## Digital Twin

This is where the concept of a *digital twin* comes into play. Taking a look at Wikipedia:

> A digital twin is a digital replica of a living or non-living physical entity

This is what many use cases require on the IoT application side. To have a digital representation of your device, 
ideally with some *magic* that keeps the data fresh, providing easy access to it.

An important part of this is to know the data structure of your device/entity. In most cases you will have a
bigger, overall data structure. However, you cannot always transmit the full set of information when changes occur.
That is why you need to transmit deltas, in order to keep traffic low. Digital twins help you to structure your device
data, and with that, allow you to more easily implement delta
updates.

## But wait, there is more

Delta update is one aspect a digital twin can help with. With a structured data model, you can also start to
normalize data. Maybe define what sensors you have, what actuators, what state they provide, and what operations
they can perform. This would allow you to map your different payload structures into re-usable schemas, and re-use
code that works with the data as well.

Having a structured data model would of course also allow for providing a structured API for your devices. Making it
easy to interact with them from the cloud side. It also allows to introspec devices, and let users explore devices
capabilities.

Based on a formal device model, it would also be possible to create some tooling around that. For example in the area
of visualization and mapping. 

## How do we get there?

So ideally we would need a way to describe device's data models, a system to store the information in these structures,
a way to interact with that data in a structured way, and an easy way to translate between our device's payload formats
and the defined models.

Let's take a look at [Eclipse Vorto](https://eclipse.org/vorto) and [Eclipse Ditto](https://eclipse.org/ditto).

Vorto describes itself as:

> Language for Digital Twins

And Ditto:

> … where IoT devices and their digital twins get together

Sounds like a perfect match. No wonder, both communities work together closely, in order to implement a digital twin
solution.

## An example

So, let's try integrating this into our cloud side deployment. Currently, our *example* temperature sensor posts
JSON snippets like this:

~~~json
{ "temp": 1.23 }
~~~

Very simple and easy to handle. If we would describe this as a Vorto model, this could look like this:

~~~
vortolang 1.0
namespace io.drogue.demo
version 1.0.0
displayname "FirstTestDevice"
description "Information Model for FirstTestDevice"

using org.eclipse.vorto.std.sensor.TemperatureSensor ; 1.0.0

infomodel FirstTestDevice {

	functionblocks {
	    mandatory temperature as TemperatureSensor
	}

}
~~~

More verbose, true. However, we also get a bunch of features with that. Like versioning, referencing existing data types,
validation, etc. As you can see, we are not defining our own temperature sensor, but already re-use a standard Vorto
model for that: `org.eclipse.vorto.std.sensor.TemperatureSensor`.

The [public Vorto repository](https://vorto.eclipse.org) already contains a bunch of models. Like the code that runs the
repository, the models can be open source as well. Of course, you can also host how own instance, if that is what
you need. But let's re-use the public instance for your example. Our model is published as
[io.drogue.demo:FirstTestDevice:1.0.0](https://vorto.eclipse.org/#/details/io.drogue.demo:FirstTestDevice:1.0.0).

If you have deployed the [digital twin](https://github.com/drogue-iot/drogue-cloud/blob/main/deploy/digitial-twin.adoc)
component from [drogue-cloud](https://github.com/drogue-iot/drogue-cloud), then you can create a new device in the
Ditto repository like this:

* Export the device model from the public repository:

  ~~~
  MODEL_ID=io.drogue.demo:FirstTestDevice:1.0.0
  http -do FirstTestDevice.json https://vorto.eclipse.org/api/v1/generators/eclipseditto/models/$MODEL_ID/?target=thingJson
  ~~~

* Create a new device in Ditto, based on this model:

  ~~~
  DEVICE_ID=my:dev1
  TWIN_API="https://ditto:ditto@ditto-console-drogue-iot.apps.my.cluster"
  
  cat FirstTestDevice.json | http PUT "$TWIN_API/api/2/things/$DEVICE_ID"
  ~~~

Now the Ditto instance is ready to receive updates for this device, in the Ditto Protocol JSON format.

## Mapping data

One feature of the Vorto repository is, that it can help you create a mapping model for your device model:

![Mapper example](vorto-mapper.svg)

You provide some example data from your device, and fill in expression where to find that data. You can even test the
mapping directly and check the results.

Once you have created the mapping, we need to inject this into our event processing. Now, the modularity and
flexibility of Knative come into play.

Let's assume we pull events from a Kafka source:

~~~yaml
apiVersion: sources.knative.dev/v1alpha1
kind: KafkaSource
metadata:
  name: digital-twin-kafka-source
spec:
  consumerGroup: digital-twin
  bootstrapServers:
    - kafka-eventing-kafka-bootstrap.knative-eventing.svc:9092
  topics:
    - knative-messaging-kafka.drogue-iot.iot-channel
  sink:
    ref:
      apiVersion: flows.knative.dev/v1
      kind: Sequence
      name: digital-twin
~~~

Forward it to the following sequence:

~~~yaml
apiVersion: flows.knative.dev/v1
kind: Sequence
metadata:
  name: digital-twin
spec:
  channelTemplate:
    …
  steps:
  - ref:
      apiVersion: serving.knative.dev/v1
      kind: Service
      name: vorto-converter
      namespace: drogue-iot
  reply:
    ref:
      kind: Service
      apiVersion: serving.knative.dev/v1
      name: ditto-pusher
~~~

The `vorto-converter` being a Knative service defined as:

~~~yaml
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: vorto-converter
spec:
  template:
    spec:
      containers:
        - image: ghcr.io/drogue-iot/vorto-converter:0.1.1
~~~

Then that would consume the original device payload from a Kafka topic, and look up the data mapper in the Vorto
repository, based on a cloud events extension, containing the *model id*. The converter is a simple Knative service,
based on Quarkus, and can be scaled up as required. The result of this would look like:

~~~json
{
  "headers":{
    "response-required":false
  },
  "path":"/features",
  "topic":"my/dev1/things/twin/commands/modify",
  "value":{
    "temperature":{
      "definition":[
        "org.eclipse.vorto.std.sensor:TemperatureSensor:1.0.0"
      ],
      "properties":{
        "status":{
          "value": 1.23
        }
      }
    }
  }
}
~~~

As you can see from the "modify" command, this is already intended to partially update the model, based on the
new information. The result would look like:

~~~json
{
    "attributes": {
        "modelDisplayName": "FirstTestDevice"
    },
    "definition": "io.drogue.demo:FirstTestDevice:1.0.0",
    "features": {
        "temperature": {
            "definition": [
                "org.eclipse.vorto.std.sensor:TemperatureSensor:1.0.0"
            ],
            "properties": {
                "status": {
                    "value": 1.23
                }
            }
        }
    },
    "policyId": "my:dev1",
    "thingId": "my:dev1"
}
~~~

As it is a simple model, with only one status value, it doesn't look that different, but I hope you get the idea.

## Developing

Getting the status of a device is easy now. A simple HTTP call is sufficient, and we can get the most recent device
state, including all information that our device supports. We have a structured data model, which we can use to build
tooling and application on, which helps us validate and map the payload that comes from our devices.

Additionally, we can also start to search for things like "all sensors reporting 5 °C or more", with
a query like: `ge(features/temperature/properties/status/value,5.0)`. So not only can we store device state,
we can also use it to find devices, based on their current state.

## What's next

I hope I was able to explain a bit, why the initial overhead of setting up a system like this makes sens, and what
the benefits are. To be fair, Knative helps lot getting this deployed on your Kubernetes cluster.

There is a lot more you can do with Digital Twins, reconciling *desired* vs *actual* state for example. But, I will
leave that for a future blog post.

## See also

* [drogue-cloud repository](https://github.com/drogue-iot/drogue-cloud)
* [Eclipse Ditto](https://eclipse.org/ditto) 
* [Eclipse Vorto](https://eclipse.org/vorto)
* [Public Vorto instance](https://vorto.eclipse.org)
* [drogue-vorto-converter repository](https://github.com/drogue-iot/drogue-vorto-converter)
