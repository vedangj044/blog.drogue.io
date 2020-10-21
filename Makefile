all: build

# we need to automate that list
build: content/2020-09-18-esp-programmer/esp.webp

# for the main image, we put in a bit more effort
# copy base images from assets
build: static/header.1920w.png static/header.768w.png
build: static/header.1920w.webp static/header.768w.webp
static/header.1920w.png: assets/header.png
	cp -p $< $@
static/header.768w.png: assets/header.png
	convert $< -resize "768" $@

# rule to resize by 50%, used for photos
%.1x.jpg: %.2x.jpg
	convert $< -resize 50% $@

# rule to convert from jpeg to webp
%.webp: %.jpg
	cwebp -m 6 $< -o $@
# rule to convert from jpeg to webp
%.webp: %.png
	cwebp -lossless $< -o $@

## Cleanup

clean:
	rm -Rf static/header*.{jpg,png,webp}

## Meta

.PHONY: all clean build
