all: build

# we need to automate that list
build: content/2020-09-18-esp-programmer/esp.webp

# for the main image, we put in a bit more effort
# copy base images from assets
build: static/header.3840w.jpg static/header.1920w.jpg static/header.768w.jpg
build: static/header.3840w.webp static/header.1920w.webp static/header.768w.webp

static/header.3840w.jpg: assets/header.png
	convert $< -resize "3840" -quality 75 $@
static/header.1920w.jpg: assets/header.png
	convert $< -resize "1920" -quality 75 $@
static/header.768w.jpg: assets/header.png
	convert $< -resize "768" -quality 75 $@

# rule to resize by 50%, used for photos
%.1x.jpg: %.2x.jpg
	convert $< -resize 50% $@

# rule to convert from jpeg to webp
%.webp: %.jpg
	cwebp -m 6 $< -o $@

## Cleanup

clean:
	rm -Rf static/header*.{jpg,webp}

## Meta

.PHONY: all clean build
