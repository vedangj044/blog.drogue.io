
## Checklist

* [ ] Provided a [summary section](#summary)
* [ ] Considered adding a [description](#description)
* [ ] Tagged the [author](#author)

## Summary

The summary is what is shown in the index overview page. It is the content before the `<!-- more -->` marker
in a page.

Example:

~~~markdown
Summary here.

<!-- more -->

Full story here.
~~~

The summary (and thus the blog post) should not start with a headline. As the blog post title is considered
to be the primary headline.

The summary supports full markdown though.

## Controlling metadata

The template should create basic metadata for each blog. However, fine-tuning the data gives better results.

### Description

The description is displayed by search engines next to the link. Like a teaser. It is not used in the ranking,
but can help people to understand what the blog post is about.

The description should be 150 - 160 characters long. Shorter is ok, longer is a problem. 

The template will use (in the following order):

* The `description` attribute from the front matter.
* The `summary`, with tags stripped.

**Note:** Providing a description is always a good idea. Consider the description kind of a sales pitch to a reader
browsing through search results. While the summary, which would take its place, is already at the start of the blog
post.

### Author

It is possible to link a post to an author. To do this:

* Add the `extra.author` attribute in the front matter, using an (made up, but unique) author id
  
  ~~~
  +++
  extra.author="itsame"
  +++
  ~~~
* Ensure there is an entry for this id in the `config.toml`
  
  ~~~toml
  [extra.authors]
  itsame = { name = "Mario" }
  ~~~ 

### Images

Each blog post can set one feature image. For Twitter, OpenGraph, or both at the same time.

The order of priority is:

* Specific image set for Twitter or OpenGraph
* Post specific image
* The default site image

This is done using the front matter:

Setting an image for a post:
~~~
+++
extra.image="<path-to-image>"
+++
~~~

Setting a specific Twitter image:
~~~
+++
extra.twitter.image="<path-to-image>"
+++
~~~

Setting a specific OpenGraph image:
~~~
+++
extra.og.image="<path-to-image>"
+++
~~~

The *path* to the image can be relative, absolute or a full URL. As the final URL has to be absolute, a relative
URL will be converted into an absolute, with the page being the parent. For example:

* The page is `content/2020-01-01-foo/index.md`
* The image is `content/2020-01-01-foo/image.png`
* The front matter has `extra.image="image.png""`
* The base URL is `http://foo.bar/`

Then the resulting image URL is: `http://foo.bar/2020-01-01-foo/image.png`.