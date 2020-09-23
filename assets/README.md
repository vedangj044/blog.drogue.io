# Original assets

## header.png

* Gets converted into different variants, optimized for the header image.
  
  **Must** be compressed lossy and should be provided in JPG and WEBP.
  
  This is done by `make clean all`

## drogue-iot_Logo_20200922.svg

* Gets converted into the `static/favicon.svg`. Adding the following section to flip the colors in *dark mode*:

    ~~~xml
    <svg>
        <style>
            @media (prefers-color-scheme: dark) {
              path { fill: #ffffff !important; }
            }
        </style>
    </svg>
    ~~~
  
  Unfortunately this is a manual operation.

* Is also used to create the `static/default_social_image.png`. Export *selection only* with Inkscape, use 300 DPI.

  Unfortunately this is a manual operation.
