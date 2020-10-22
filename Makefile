all: build

# we need to automate that list
build: content/2020-09-18-esp-programmer/esp.webp

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

## Meta

.PHONY: all clean build
