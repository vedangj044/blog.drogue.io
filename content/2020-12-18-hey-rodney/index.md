+++
title = "\"Hey Rodney, … restart console pods\""
description = "Creating a voice assistant with Drogue IoT, Knative, and a few others, learning some lessons on the way."
extra.author = "ctron"
+++

Pushing temperature readings in JSON structures to the cloud is fun, but more fun is to restart your pods by saying:
"Hey Rodney, …". It also is a nice demo, and a good test, to see what fails when your `Content-Type` is `audio/wav`
instead of `application/json`.

<!-- more -->

I tried to create a very basic voice assistant during last years holiday seasons. Letting the kids come up with ideas
for some interactions, coming up with some funny responses. The project failed miserably, as most of the services around
that turned out to have some serious flaw. Performing wake word detection and speech recognition is challenge, so I
was looking out for some existing solutions already. However, my aspiration was still to assemble the different components
myself, rather than simply installing a ready-to-run solution like [Mycroft](https://mycroft.ai/).

## Restarting pods

While working on the web console, I had to restart the pods a few times. I can turn on my lights with a voice command,
while typing code at the same time. So why can't I restart the container pods that way? Besides, I was looking for
some use case of processing non-JSON payload, running some "edge" agent with some "processing" workflow, and some
cloud -side analytics. Turns out, a voice assistant has all of those requirements, and I had a little bit of experience
from last year's failure.

## The setup

The task feels rather simple:
* Listen for a wake word or phrase ("Hey Rodney", though Star Trek fans might prefer "computer").
* Recognize words after the wake-word, until some stop condition is reached
* Evaluate the actions to take
* Perform the evaluated actions, possibly giving some acoustic feedback ("I'm sorry Dave, I'm afraid I can't do that.")

Sounds easy, eh?

### Wake word detection

I started with [Mycroft Precise](https://github.com/MycroftAI/mycroft-precise), an open source wake word listener. It
is a nightmare to build that. Outdated Python dependencies, a poorly maintained repository, a broken build, and some
forks trying to fix that. Also, it would have been necessary to train our own model for having our own wake-word.
However, I didn't want to become an expert on machine learning just yet.

The predecessor for Mycroft was [Pocketsphinx](https://github.com/cmusphinx/pocketsphinx), as research project of the
Carnegie Mellon University. If has some Python bindings that made my life easier, and it also has a dictionary, which
allows you to provide keywords in text form, rather than requiring you to train your own model. The downside is, it
is not as accurate, but I assumed it is good enough for our use case.

It also has the capability to detect "silence", so it was easy to implement a logic of:

* Wait for the wake-word
* Start recording
* Record at least x seconds, stop when detecting silence or more than y seconds have passed
* Send recording to the cloud

Sending that to the cloud side was rather easy with the Drogue IoT setup that I already had. So the data ends up
in a Kafka stream, encoded as a Cloud Event with a content type of `audio/wav`, ready to be processed.

### Speech-to-text

I didn't want to start with speech-to-text transformation on a Raspberry Pi. I tried out
[Vosk](https://alphacephei.com/vosk/), which is based on [Kaldi](https://kaldi-asr.org/), however the speech
recognition was far from optimal. I just gave up on that and picked a service I had played with before:
[IBM Watson Speech-to-Text](https://cloud.ibm.com/apidocs/speech-to-text).

As events already get processed through Knative eventing, it is easy to replace any of the components in play:

~~~yaml
apiVersion: flows.knative.dev/v1
kind: Sequence
metadata:
  name: hey-rodney
spec:
  channelTemplate: …
  steps:
    - ref:
        apiVersion: serving.knative.dev/v1
        kind: Service
        name: watson-stt-converter
  reply:
    ref:
      kind: Service
      apiVersion: serving.knative.dev/v1
      name: hey-rodney-backend
~~~

The functionality is in the [watson-speech-to-text-converter ](https://github.com/orgs/drogue-iot/packages/container/package/watson-speech-to-text-converter)
container. It simply is converting audio events to JSON events, and I think it would be fun to see this replaced with
an open source version.

### Evaluating commands

My goal was to restart container pods. So yes, I did take a nasty shortcut. [A simple Quarkus application](https://github.com/drogue-iot/hey-rodney-backend)
which does some regular expression matching in the incoming transcribed audio, and executes the configured commands:

~~~yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hey-rodney-config
data:
  rules.yaml: |
    rules:
      - matcher: restart console (pods|parts|pots|ports|plots)
        commands:
          - execute: [ "kubectl", "delete", "pods", "-l", "app=console-backend"]
          - execute: [ "kubectl", "delete", "pods", "-l", "app=console-frontend"]
~~~

If you think that is a crude way of doing things, I absolutely agree. PRs welcome 😁

## Lessons learned

Processing audio is much harder than anticipated. The right microphone, the best wake-word solution, timing, struggles
with ALSA and passing in audio devices to containers. The demo leaves much room for improvement. On the other side,
the demo is just that: a demo.

### Compressing payload

Cloud Events proposes to [keep events compact](https://github.com/cloudevents/spec/blob/v1.0.1/spec.md#size-limits),
and proposes a limit of 64 KiB. That may just be a little too much for a few seconds of 16 kHz audio.

However, there is the [OPUS codec](https://opus-codec.org/), an open and royalty-free audio codec, for speech amongst
other things. A Raspberry Pi 4 can encode the few seconds of audio in around 200ms:

~~~
Recorded 4.9 seconds of audio
Encoding time: 0.2 s
Payload size: 9.7KiB
~~~

Compared to the original size of the audio, this is a significant improvement:

~~~
Recorded 4.9 seconds of audio
Payload size: 162.7KiB
~~~

### Modularity through Knative eventing

Using Knative eventing, and more specifically Cloud Events made things much simpler. Re-using the HTTP endpoint for
ingesting payload from the device, the speech-to-text container, the custom Quarkus application. All wired up using
YAML from inside Kubernetes. It also makes testing different components much simpler. Instead of orchestrating a
big system test, with all kinds of messaging components, only a few, simple HTTP based tests are required, and you can
test each component in isolation.

![Architecture](architecture.svg)

### Scaling down to zero can get in your way

Scaling down to zero is great, but not when it comes to creating a voice assistant. Spinning up pods with Rust and
Quarkus native is rather quick. Still, it takes a few milliseconds here and there and feels like a big lag. Yes, there
is a simple solution to that, don't scale down to zero 😉. If latency is important to you, you can still have all the
benefits.

## What's next

Currently, there is no way to response back to a device. "Command & control" is a feature that we are currently working
on. A first version has already landed in the `main` branch, but it is too early to work with that already. This means
that it is also not possible yet to send some audio back to the speaker. However, once we have C&C, sending JSON back
the chain, converting from text to speech, shouldn't be a big deal with the setup we have. The beauty of Cloud Events.

Please don't forget: this is just an example. We don't want to replicate a solution like Mycroft. So, there are no real
plans on "what to do next".

Then again: It would be great to bring this solution on some embedded device. Tensorflow Lite runs on microcontrollers
as well. So we could port the wake-word and audio-snippet-recording part to some embedded device, and keep the
rest of the pipeline as is. Maybe you are interested in a Google Summer of Code project: [Implement "Hey Rodney" Drogue IoT demo using Tensorflow (Lite)](https://docs.jboss.org/display/GSOC/Google+Summer+of+Code+2021+Ideas) 😉. 

## Mission accomplished?

Kind of. It was fun, I learned a lot! It sits there, runs on a Raspberry Pi, and after a few attempts, it restarts
the console pods. Accuracy could be much better. Then again, that lets you have more respect for the smart speaker
you might have at home.

If you want to replicate this, bring some time and patience, and take a look at the links below.

## See also

* [hey-rodney repository](https://github.com/drogue-iot/hey-rodney)
* [hey-rodney-backend repository](https://github.com/drogue-iot/hey-rodney-backend)
* [drogue-cloud repository](https://github.com/drogue-iot/drogue-cloud)
