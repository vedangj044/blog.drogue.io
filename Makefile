all: build

build: static/wood.2x.jpg static/wood.1x.jpg
build: static/wood.2x.webp static/wood.1x.webp

# copy base image from assets
static/wood.2x.jpg: assets/wood.jpg
	convert $< -shave "0x30%" $@

# pattern to shrink to 50%
%.1x.jpg: %.2x.jpg
	convert $< -resize 50% $@
# rule to convert from jpeg to webp
%.webp: %.jpg
	cwebp -m 6 $< -o $@

## Cleanup

clean:
	rm -Rf static/wood*.{jpg,webp}

## Meta

.PHONY: all clean build
